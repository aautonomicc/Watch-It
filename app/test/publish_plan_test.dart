import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/publish_plan.dart';

MediaProbe video({
  int height = 1080,
  int width = 1920,
  String codec = 'h264',
  String pixFmt = 'yuv420p',
  String? audio = 'aac',
  String container = 'mov,mp4,m4a,3gp,3g2,mj2',
  double? duration = 3600,
}) =>
    MediaProbe(
      hasVideo: true,
      width: width,
      height: height,
      videoCodec: codec,
      pixelFormat: pixFmt,
      hasAudio: audio != null,
      audioCodec: audio,
      container: container,
      durationSeconds: duration,
    );

void main() {
  group('offeredTiers', () {
    test('unprobed file: original only', () {
      expect(offeredTiers(null), [PublishTier.original]);
    });

    test('audio-only: original only', () {
      const probe = MediaProbe(hasAudio: true, audioCodec: 'mp3');
      expect(offeredTiers(probe), [PublishTier.original]);
    });

    test('4K HEVC: all encode tiers, original offered last', () {
      final probe = video(height: 2160, codec: 'hevc', pixFmt: 'yuv420p10le');
      expect(offeredTiers(probe), [
        PublishTier.high,
        PublishTier.medium,
        PublishTier.low,
        PublishTier.original,
      ]);
    });

    test('1080p universal: original replaces High', () {
      expect(offeredTiers(video()), [
        PublishTier.original,
        PublishTier.medium,
        PublishTier.low,
      ]);
    });

    test('720p universal: original replaces Medium, no upscale to High', () {
      expect(offeredTiers(video(height: 720)),
          [PublishTier.original, PublishTier.low]);
    });

    test('720p HEVC: Medium/Low only, original last', () {
      final probe = video(height: 720, codec: 'hevc');
      expect(offeredTiers(probe),
          [PublishTier.medium, PublishTier.low, PublishTier.original]);
    });

    test('480p universal: as-is only', () {
      expect(offeredTiers(video(height: 480)), [PublishTier.original]);
    });

    test('tiny non-universal source still gets Low (no upscale)', () {
      final probe = video(height: 360, codec: 'vp9', container: 'matroska,webm');
      expect(offeredTiers(probe), [PublishTier.low, PublishTier.original]);
    });

    test('1440p H.264 is not universal (over 1080p): original last', () {
      final probe = video(height: 1440);
      expect(offeredTiers(probe).first, PublishTier.high);
      expect(offeredTiers(probe).last, PublishTier.original);
    });
  });

  group('defaultTiers', () {
    test('universal source: everything ticked', () {
      expect(defaultTiers(video()), offeredTiers(video()));
    });

    test('non-universal source: original starts unticked', () {
      final probe = video(height: 2160, codec: 'hevc');
      expect(defaultTiers(probe),
          [PublishTier.high, PublishTier.medium, PublishTier.low]);
    });
  });

  group('probeVerdict', () {
    test('universal', () {
      expect(probeVerdict(video()), '1080p H.264 — plays everywhere.');
    });

    test('exotic codec warns', () {
      final v = probeVerdict(video(height: 2160, codec: 'hevc', pixFmt: 'yuv420p10le'));
      expect(v, contains('2160p HEVC 10-bit'));
      expect(v, contains("can't play"));
    });

    test('unprobed', () {
      expect(probeVerdict(null), contains('as-is'));
    });

    test('audio', () {
      const probe = MediaProbe(hasAudio: true, audioCodec: 'mp3');
      expect(probeVerdict(probe), 'Audio · MP3 — published as-is.');
    });
  });

  group('tierOutputName', () {
    test('episode name gains the tier tag as mp4', () {
      expect(tierOutputName('Show S01E02.mkv', PublishTier.medium),
          'Show S01E02 [720p].mp4');
    });

    test('existing resolution tag is replaced', () {
      expect(
          tierOutputName('Night of the Living Dead (1968) '
              '{imdb-tt0063350} - [1080p].mp4', PublishTier.low),
          'Night of the Living Dead (1968) {imdb-tt0063350} [480p].mp4');
    });

    test('original keeps the source name', () {
      expect(tierOutputName('Show S01E02.mkv', PublishTier.original),
          'Show S01E02.mkv');
    });

    test('sub-480p source: tag is the real output resolution', () {
      expect(
          tierOutputName('Old Short.avi', PublishTier.low,
              video(width: 480, height: 360)),
          'Old Short [360p].mp4');
    });

    test('odd source height snaps down to even like the encoder', () {
      expect(
          tierOutputName('Old Short.avi', PublishTier.low,
              video(width: 512, height: 361)),
          'Old Short [360p].mp4');
    });

    test('source at or above the tier height keeps the tier tag', () {
      expect(
          tierOutputName('Show.mkv', PublishTier.medium,
              video(width: 1920, height: 1080)),
          'Show [720p].mp4');
      expect(
          tierOutputName('Show.mkv', PublishTier.low,
              video(width: 854, height: 480)),
          'Show [480p].mp4');
    });

    test('unprobed source falls back to the nominal tier tag', () {
      expect(tierOutputName('Show.mkv', PublishTier.low, null),
          'Show [480p].mp4');
    });
  });

  group('tierOutputHeight + tierLabel', () {
    test('caps at the tier height', () {
      expect(tierOutputHeight(video(height: 2160), PublishTier.high), 1080);
      expect(tierLabel(video(height: 2160), PublishTier.high), '1080p');
    });

    test('smaller source keeps its (even-snapped) height', () {
      expect(tierOutputHeight(video(height: 360), PublishTier.low), 360);
      expect(tierOutputHeight(video(height: 361), PublishTier.low), 360);
      expect(tierLabel(video(height: 240), PublishTier.low), '240p');
    });

    test('original and unknown heights', () {
      expect(tierOutputHeight(video(height: 360), PublishTier.original), null);
      expect(tierOutputHeight(null, PublishTier.low), null);
      expect(tierLabel(null, PublishTier.low), '480p');
    });
  });

  group('size + cost prediction', () {
    test('predicted size from tier bitrate × duration', () {
      // (2500+128) kbps over an hour, +2% overhead.
      expect(predictedSizeBytes(video(), PublishTier.medium, 999),
          (3600 * 2628000 / 8 * 1.02).round());
    });

    test('original tier predicts the source size', () {
      expect(predictedSizeBytes(video(), PublishTier.original, 999), 999);
    });

    test('unknown duration: no prediction', () {
      expect(
          predictedSizeBytes(video(duration: null), PublishTier.low, 9), null);
    });

    test('chunk floor is 3', () {
      expect(approxChunks(1), 3);
      expect(approxChunks(4 * 1024 * 1024), 3);
      expect(approxChunks(40 * 1024 * 1024), 10);
    });

    test('cost scales per chunk from the reference estimate', () {
      final ref = BigInt.parse('250000000000000000'); // 0.25 ANT, 3 chunks
      // 10 chunks at the same per-chunk rate; division last keeps a
      // 3-chunk file at exactly the reference cost.
      expect(approxCostAtto(40 * 1024 * 1024, ref, 3),
          ref * BigInt.from(10) ~/ BigInt.from(3));
      expect(approxCostAtto(5, ref, 3), ref);
    });
  });

  group('buildQueue', () {
    test('selection intersects per-file applicability', () {
      final series = [
        PublishSource(
            path: '/a/E01.mkv',
            name: 'Show S01E01.mkv',
            size: 100,
            probe: video(height: 1080, codec: 'hevc')),
        PublishSource(
            path: '/a/E02.mp4',
            name: 'Show S01E02.mp4',
            size: 200,
            probe: video(height: 720)),
      ];
      final queue = buildQueue(series, {
        PublishTier.high,
        PublishTier.medium,
        PublishTier.original,
      });
      // E01 (1080p HEVC): High + Medium apply, original selected too.
      // E02 (720p universal): original + (no High/Medium — Medium is
      // replaced by original for a universal 720p source).
      expect(
          queue.map((i) => '${i.source.name}:${i.tier.name}').toList(), [
        'Show S01E01.mkv:high',
        'Show S01E01.mkv:medium',
        'Show S01E01.mkv:original',
        'Show S01E02.mp4:original',
      ]);
      expect(queue.first.outputName, 'Show S01E01 [1080p].mp4');
      expect(queue.first.needsEncode, true);
      expect(queue.last.needsEncode, false);
    });
  });

  group('encodeArgs', () {
    test('downscales a larger source', () {
      final args = encodeArgs(
          input: 'in.mkv',
          output: 'out.mp4',
          tier: PublishTier.medium,
          probe: video(height: 2160, width: 3840));
      expect(args, containsAllInOrder(['-vf', 'scale=-2:720']));
      expect(args, containsAllInOrder(['-b:v', '2500k']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args, containsAllInOrder(['-progress', 'pipe:1']));
    });

    test('no scale filter at or below tier height', () {
      final args = encodeArgs(
          input: 'in.mp4',
          output: 'out.mp4',
          tier: PublishTier.high,
          probe: video(height: 1080));
      expect(args, isNot(contains('-vf')));
    });

    test('odd dimensions snapped to even without upscaling', () {
      final args = encodeArgs(
          input: 'in.avi',
          output: 'out.mp4',
          tier: PublishTier.low,
          probe: video(height: 479, width: 639));
      expect(args,
          containsAllInOrder(['-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2']));
    });
  });
}
