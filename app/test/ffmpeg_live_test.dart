import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/publish_plan.dart';

/// Live probe + encode through the real ffmpeg/ffprobe binaries.
/// Skipped when they aren't on the box (e.g. CI) — parser coverage lives
/// in ffmpeg_test.dart either way.
void main() {
  late FfmpegService service;
  late Directory dir;

  setUp(() {
    service = FfmpegService();
    dir = Directory.systemTemp.createTempSync('wi-ffmpeg-live');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// A 2s 640x480 10-bit H.264 + AAC test clip in MKV — deliberately
  /// NOT universal (10-bit, matroska) so a Low encode has real work.
  Future<String> generateClip() async {
    final source = '${dir.path}/Tiny S01E01.mkv';
    final gen = await Process.run('ffmpeg', [
      '-v', 'error',
      '-f', 'lavfi', '-i', 'testsrc2=size=640x480:rate=10:duration=2',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p10le',
      '-c:a', 'aac', '-shortest', '-y', source,
    ]);
    expect(gen.exitCode, 0, reason: gen.stderr as String);
    return source;
  }

  test('probe → tiers → encode → universal output with progress', () async {
    if (!await service.available) {
      markTestSkipped('ffmpeg/ffprobe not installed');
      return;
    }
    final source = await generateClip();

    final probe = await service.probe(source);
    expect(probe, isNotNull);
    expect(probe!.hasVideo, true);
    expect(probe.videoCodec, 'h264');
    expect(probe.pixelFormat, 'yuv420p10le');
    expect(probe.isUniversal, false);
    expect(probe.durationSeconds, closeTo(2, 0.5));
    expect(offeredTiers(probe), [PublishTier.low, PublishTier.original]);

    final outputName = tierOutputName('Tiny S01E01.mkv', PublishTier.low);
    expect(outputName, 'Tiny S01E01 [480p].mp4');
    final output = '${dir.path}/$outputName';
    final fractions = <double?>[];
    await service.encode(
      input: source,
      output: output,
      tier: PublishTier.low,
      probe: probe,
      onProgress: fractions.add,
    );
    expect(File(output).existsSync(), true);
    expect(fractions.last, 1);

    final outProbe = await service.probe(output);
    expect(outProbe!.isUniversal, true,
        reason: 'encoded tier must play everywhere');
    expect(outProbe.height, 480);
  });

  test('extractFrame grabs JPEG frames without upscaling', () async {
    if (!await service.available) {
      markTestSkipped('ffmpeg/ffprobe not installed');
      return;
    }
    final source = await generateClip();

    final frame = await service.extractFrame(
        source: source, atSeconds: 1.0, maxHeight: 240);
    expect(frame, isNotNull);
    // JPEG magic — the picker feeds these bytes to Image.memory.
    expect(frame!.sublist(0, 2), [0xFF, 0xD8]);

    // A cap above the source height must not upscale (480p source).
    final full = await service.extractFrame(
        source: source, atSeconds: 0.5, maxHeight: 720);
    final saved = File('${dir.path}/frame.jpg')
      ..writeAsBytesSync(full!);
    final probed = await service.probe(saved.path);
    expect(probed!.height, 480);

    // Out-of-range timestamp → no frame, not a crash.
    final beyond = await service.extractFrame(
        source: source, atSeconds: 99.0, maxHeight: 240);
    expect(beyond, isNull);
  });

  test('encode failure throws with ffmpeg detail', () async {
    if (!await service.available) {
      markTestSkipped('ffmpeg/ffprobe not installed');
      return;
    }
    await expectLater(
      service.encode(
        input: '${dir.path}/does-not-exist.mkv',
        output: '${dir.path}/out.mp4',
        tier: PublishTier.low,
      ),
      throwsA(isA<FfmpegException>()),
    );
  });
}
