import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/ffmpeg.dart';

const _videoJson = '''
{
  "streams": [
    {"codec_type": "video", "codec_name": "hevc", "width": 3840,
     "height": 2160, "pix_fmt": "yuv420p10le",
     "disposition": {"attached_pic": 0}},
    {"codec_type": "audio", "codec_name": "eac3",
     "disposition": {"attached_pic": 0}}
  ],
  "format": {"format_name": "matroska,webm", "duration": "5423.040000"}
}
''';

const _mp3CoverArtJson = '''
{
  "streams": [
    {"codec_type": "audio", "codec_name": "mp3",
     "disposition": {"attached_pic": 0}},
    {"codec_type": "video", "codec_name": "mjpeg", "width": 500,
     "height": 500, "disposition": {"attached_pic": 1}}
  ],
  "format": {"format_name": "mp3", "duration": "181.2"}
}
''';

void main() {
  group('parseProbeJson', () {
    test('video + audio streams and format fields', () {
      final probe = FfmpegService.parseProbeJson(_videoJson)!;
      expect(probe.hasVideo, true);
      expect(probe.height, 2160);
      expect(probe.videoCodec, 'hevc');
      expect(probe.pixelFormat, 'yuv420p10le');
      expect(probe.hasAudio, true);
      expect(probe.audioCodec, 'eac3');
      expect(probe.container, 'matroska,webm');
      expect(probe.durationSeconds, closeTo(5423.04, 0.001));
      expect(probe.isUniversal, false);
    });

    test('mp3 cover art is not video', () {
      final probe = FfmpegService.parseProbeJson(_mp3CoverArtJson)!;
      expect(probe.hasVideo, false);
      expect(probe.hasAudio, true);
      expect(probe.audioCodec, 'mp3');
    });

    test('no streams / garbage → null', () {
      expect(FfmpegService.parseProbeJson('{"format": {}}'), null);
      expect(FfmpegService.parseProbeJson('not json'), null);
    });
  });

  group('parseProgressLine', () {
    test('out_time_us against the duration', () {
      expect(FfmpegService.parseProgressLine('out_time_us=30000000', 60),
          closeTo(0.5, 1e-9));
    });

    test('clamps past the end', () {
      expect(
          FfmpegService.parseProgressLine('out_time_us=99000000', 60), 1.0);
    });

    test('other keys and missing duration are ignored', () {
      expect(FfmpegService.parseProgressLine('frame=100', 60), null);
      expect(
          FfmpegService.parseProgressLine('out_time_us=1000', null), null);
    });
  });
}
