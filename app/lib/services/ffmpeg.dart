import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'publish_plan.dart';

/// ffmpeg/ffprobe integration for Publish quality tiers.
///
/// Binaries are found beside the app executable first — the AppImage and
/// the Windows zip bundle static builds there — with a PATH fallback for
/// dev boxes. When neither exists Publish still works, just without
/// probing or encode tiers (files go up as-is).
class FfmpegService {
  FfmpegService();

  String? _ffmpeg;
  String? _ffprobe;
  bool _located = false;
  Process? _current;

  Future<bool> get available async {
    await _locate();
    return _ffmpeg != null && _ffprobe != null;
  }

  Future<void> _locate() async {
    if (_located) return;
    _located = true;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final ext = Platform.isWindows ? '.exe' : '';
    Future<String?> pick(String name) async {
      final bundled = '$exeDir${Platform.pathSeparator}$name$ext';
      if (File(bundled).existsSync()) return bundled;
      try {
        final result = await Process.run(name, ['-version']);
        if (result.exitCode == 0) return name;
      } catch (_) {}
      return null;
    }

    _ffmpeg = await pick('ffmpeg');
    _ffprobe = await pick('ffprobe');
  }

  /// Probe a media file; null when ffprobe is missing or the file isn't
  /// something it understands (both mean: offer as-is publishing only).
  Future<MediaProbe?> probe(String path) async {
    await _locate();
    final ffprobe = _ffprobe;
    if (ffprobe == null) return null;
    try {
      final result = await Process.run(ffprobe, [
        '-v', 'error',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        path,
      ]);
      if (result.exitCode != 0) return null;
      return parseProbeJson(result.stdout as String);
    } catch (_) {
      return null;
    }
  }

  /// Encode [input] to a tier at [output], reporting progress as a 0–1
  /// fraction (null = unknown/indeterminate). Throws [FfmpegException]
  /// with ffmpeg's stderr tail on failure.
  Future<void> encode({
    required String input,
    required String output,
    required PublishTier tier,
    MediaProbe? probe,
    void Function(double? fraction)? onProgress,
  }) async {
    await _locate();
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) throw FfmpegException('ffmpeg is not available');
    final args = encodeArgs(
        input: input, output: output, tier: tier, probe: probe);
    onProgress?.call(probe?.durationSeconds == null ? null : 0);
    final process = await Process.start(ffmpeg, args);
    _current = process;
    final stderrTail = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) {
      stderrTail.write(chunk);
      if (stderrTail.length > 4096) {
        final s = stderrTail.toString();
        stderrTail
          ..clear()
          ..write(s.substring(s.length - 4096));
      }
    });
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      final fraction = parseProgressLine(line, probe?.durationSeconds);
      if (fraction != null) onProgress?.call(fraction);
    });
    final exitCode = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    _current = null;
    if (exitCode != 0) {
      final detail = stderrTail.toString().trim();
      throw FfmpegException(
          'encoding failed${detail.isEmpty ? ' (exit $exitCode)' : ': $detail'}');
    }
    onProgress?.call(1);
  }

  /// Kill an in-flight encode (leaving the screen mid-batch).
  void cancel() {
    _current?.kill();
    _current = null;
  }

  Process? _frameProcess;

  /// Grab one frame of [source] at [atSeconds] as JPEG bytes; null when
  /// ffmpeg is missing or the grab fails (bad timestamp, unreadable
  /// source). [source] may be a local file or an HTTP URL — the embedded
  /// client's stream URL works, each seek costing range requests. Height
  /// is capped at [maxHeight] (never upscaled, even-snapped for the JPEG
  /// encoder's chroma subsampling).
  Future<Uint8List?> extractFrame({
    required String source,
    required double atSeconds,
    int maxHeight = 720,
  }) async {
    await _locate();
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) return null;
    try {
      // -ss before -i: keyframe-accurate fast seek — right for sampling
      // representative frames, and the only affordable mode over HTTP.
      final process = await Process.start(ffmpeg, [
        '-v', 'error',
        '-ss', atSeconds.toStringAsFixed(3),
        '-i', source,
        '-frames:v', '1',
        '-vf', 'scale=-2:2*trunc(min($maxHeight\\,ih)/2)',
        '-f', 'image2pipe',
        '-vcodec', 'mjpeg',
        'pipe:1',
      ]);
      _frameProcess = process;
      final out = BytesBuilder(copy: false);
      final stdoutDone = process.stdout.forEach(out.add);
      final stderrDone = process.stderr.drain<void>();
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      _frameProcess = null;
      if (exitCode != 0 || out.isEmpty) return null;
      return out.takeBytes();
    } catch (_) {
      _frameProcess = null;
      return null;
    }
  }

  /// Kill an in-flight frame grab (closing the frame picker mid-sample).
  void cancelFrameExtraction() {
    _frameProcess?.kill();
    _frameProcess = null;
  }

  /// `-progress pipe:1` key=value line → completed fraction, using the
  /// source duration; null for lines that carry no time.
  static double? parseProgressLine(String line, double? durationSeconds) {
    if (durationSeconds == null || durationSeconds <= 0) return null;
    final match = RegExp(r'^out_time_us=(\d+)').firstMatch(line.trim());
    if (match == null) return null;
    final seconds = int.parse(match.group(1)!) / 1e6;
    final fraction = seconds / durationSeconds;
    return fraction.clamp(0.0, 1.0);
  }

  /// Parse `ffprobe -print_format json -show_format -show_streams` output.
  /// Cover art in audio files shows up as an attached-pic video stream and
  /// is ignored — an MP3 with embedded artwork is still audio.
  static MediaProbe? parseProbeJson(String text) {
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final streams = (json['streams'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      Map<String, dynamic>? video;
      Map<String, dynamic>? audio;
      for (final stream in streams) {
        final type = stream['codec_type'];
        final attachedPic =
            (stream['disposition'] as Map?)?['attached_pic'] == 1;
        if (type == 'video' && !attachedPic) {
          video ??= stream;
        } else if (type == 'audio') {
          audio ??= stream;
        }
      }
      final format = json['format'] as Map<String, dynamic>? ?? const {};
      if (video == null && audio == null) return null;
      return MediaProbe(
        hasVideo: video != null,
        width: video?['width'] as int?,
        height: video?['height'] as int?,
        videoCodec: video?['codec_name'] as String?,
        pixelFormat: video?['pix_fmt'] as String?,
        hasAudio: audio != null,
        audioCodec: audio?['codec_name'] as String?,
        container: format['format_name'] as String?,
        durationSeconds:
            double.tryParse(format['duration'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

class FfmpegException implements Exception {
  FfmpegException(this.message);
  final String message;
  @override
  String toString() => message;
}
