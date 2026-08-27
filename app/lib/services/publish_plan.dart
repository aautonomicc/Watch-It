import 'dart:math' as math;

/// Publish tier planning — pure logic, no I/O.
///
/// Turns ffprobe results into offered quality tiers per file (no
/// upscaling; "Original" replaces the matching encode tier when the
/// source already plays everywhere), predicts encoded sizes and ANT
/// costs, names outputs per docs/NAMING.md, and builds the batch
/// encode/upload queue the Publish screen runs.

/// What ffprobe learned about a picked file. Null probe = the file could
/// not be probed (no ffprobe on the box, or not a media file) — it can
/// still be published as-is.
class MediaProbe {
  const MediaProbe({
    this.hasVideo = false,
    this.width,
    this.height,
    this.videoCodec,
    this.pixelFormat,
    this.hasAudio = false,
    this.audioCodec,
    this.container,
    this.durationSeconds,
  });

  final bool hasVideo;
  final int? width;
  final int? height;

  /// ffprobe codec_name, e.g. `h264`, `hevc`, `av1`.
  final String? videoCodec;

  /// e.g. `yuv420p` (8-bit, universal) vs `yuv420p10le` (10-bit).
  final String? pixelFormat;
  final bool hasAudio;
  final String? audioCodec;

  /// ffprobe format_name, e.g. `mov,mp4,m4a,3gp,3g2,mj2` or `matroska,webm`.
  final String? container;
  final double? durationSeconds;

  /// Plays everywhere without re-encoding: H.264 8-bit + AAC/MP3 audio in
  /// an MP4 container, at most 1080p (what we learned shipping NOTLD).
  bool get isUniversal =>
      hasVideo &&
      videoCodec == 'h264' &&
      pixelFormat == 'yuv420p' &&
      (!hasAudio || audioCodec == 'aac' || audioCodec == 'mp3') &&
      (container?.split(',').contains('mp4') ?? false) &&
      (height ?? 0) <= 1080;
}

enum PublishTier { high, medium, low, original }

class TierSpec {
  const TierSpec(this.tier, this.height, this.videoKbps, this.audioKbps,
      this.label, this.name);
  final PublishTier tier;
  final int height;
  final int videoKbps;
  final int audioKbps;

  /// Quality tag for output names, e.g. `720p`.
  final String label;

  /// UI name, e.g. `Medium`.
  final String name;
}

const kTierSpecs = <PublishTier, TierSpec>{
  PublishTier.high: TierSpec(PublishTier.high, 1080, 5000, 160, '1080p', 'High'),
  PublishTier.medium:
      TierSpec(PublishTier.medium, 720, 2500, 128, '720p', 'Medium'),
  PublishTier.low: TierSpec(PublishTier.low, 480, 1000, 96, '480p', 'Low'),
};

const kEncodeTierOrder = [PublishTier.high, PublishTier.medium, PublishTier.low];

/// Tiers offered for a file, best first. Encode tiers never upscale; when
/// even Low would (source under 480p), Low is still offered and encodes at
/// the source resolution. "Original" is first (replacing the top encode
/// tier) when the source already plays everywhere, and last otherwise —
/// available, but flagged by the verdict text.
List<PublishTier> offeredTiers(MediaProbe? probe) {
  if (probe == null || !probe.hasVideo) return const [PublishTier.original];
  final height = probe.height ?? 0;
  var encode = kEncodeTierOrder
      .where((t) => kTierSpecs[t]!.height <= height)
      .toList();
  if (encode.isEmpty) encode = [PublishTier.low];
  if (probe.isUniversal) {
    return [PublishTier.original, ...encode.skip(1)];
  }
  return [...encode, PublishTier.original];
}

/// Default selection: every offered tier, except that "Original" starts
/// unticked for sources that don't play everywhere (publishing them as-is
/// is possible but rarely what a series uploader wants).
List<PublishTier> defaultTiers(MediaProbe? probe) {
  final offered = offeredTiers(probe);
  if (probe != null && probe.hasVideo && !probe.isUniversal) {
    return offered.where((t) => t != PublishTier.original).toList();
  }
  return offered;
}

/// Plain-English one-liner about a probed file.
String probeVerdict(MediaProbe? probe) {
  if (probe == null) {
    return 'Could not read this file — it can only be published as-is.';
  }
  if (!probe.hasVideo) {
    final codec = probe.audioCodec?.toUpperCase();
    return probe.hasAudio
        ? 'Audio${codec == null ? '' : ' · $codec'} — published as-is.'
        : 'Not a media file — published as-is.';
  }
  final bits = probe.pixelFormat?.contains('10') ?? false ? ' 10-bit' : '';
  final codecName = videoCodecName(probe.videoCodec) ?? 'unknown codec';
  final res = probe.height != null ? '${probe.height}p ' : '';
  if (probe.isUniversal) {
    return '$res$codecName — plays everywhere.';
  }
  return '$res$codecName$bits — many devices can\'t play this; '
      'the encoded qualities are recommended.';
}

/// Display name for an ffprobe video codec, `h264 → H.264`. Null in,
/// null out; unrecognized codecs are uppercased.
String? videoCodecName(String? codec) => switch (codec) {
      'h264' => 'H.264',
      'hevc' => 'HEVC',
      'av1' => 'AV1',
      'vp9' => 'VP9',
      null => null,
      final c => c.toUpperCase(),
    };

/// `480p H.264` — the format label a published output should carry as its
/// library entry's videoInfo (the version picker and cards show it next
/// to the size, same style as the seed catalog's). Encode tiers are
/// always H.264 at their real output height; Original keeps the source's
/// probed height/codec. Null when nothing is known about the source.
String? tierVideoInfo(MediaProbe? probe, PublishTier tier) {
  if (tier != PublishTier.original) return '${tierLabel(probe, tier)} H.264';
  if (probe == null || !probe.hasVideo) return null;
  final parts = [
    if ((probe.height ?? 0) > 0) '${probe.height}p',
    ?videoCodecName(probe.videoCodec),
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// Real encoded height for an encode tier of a given source: the tier
/// height, or the source height when that is smaller (encoding never
/// upscales), snapped down to even exactly like [encodeArgs] does. Null
/// for Original and when the source height is unknown.
int? tierOutputHeight(MediaProbe? probe, PublishTier tier) {
  if (tier == PublishTier.original) return null;
  final height = probe?.height;
  if (height == null || height <= 0) return null;
  final spec = kTierSpecs[tier]!;
  return height >= spec.height ? spec.height : height - (height % 2);
}

/// Quality tag for a tier's output of a given source, e.g. `480p` — or the
/// real lower resolution (`360p`) when the source is below the tier height.
/// Falls back to the tier's nominal label when the source is unprobed.
String tierLabel(MediaProbe? probe, PublishTier tier) {
  final height = tierOutputHeight(probe, tier);
  return height == null ? kTierSpecs[tier]!.label : '${height}p';
}

/// Output file name for a tier, per docs/NAMING.md: any existing
/// resolution tag is replaced with the real output resolution
/// ([tierLabel]), extension becomes .mp4. `Show S01E02.mkv` →
/// `Show S01E02 [720p].mp4`; a 360p source at Low → `… [360p].mp4`.
/// Original keeps the source name untouched — except a universal source
/// (already-plays-everywhere H.264, where Original stands in for the top
/// encode tier), which gains its real resolution tag so it matches the
/// encoded siblings: a 1080p `Movie.mp4` → `Movie [1080p].mp4`.
/// Non-universal originals stay untagged (a tag there could collide with
/// the same-resolution encode tier's output name).
String tierOutputName(String sourceName, PublishTier tier,
    [MediaProbe? probe]) {
  final dot = sourceName.lastIndexOf('.');
  var base = dot > 0 ? sourceName.substring(0, dot) : sourceName;
  base = base.replaceAll(RegExp(r'\s*-?\s*\[\d{3,4}p\]'), '').trim();
  if (tier == PublishTier.original) {
    final height = probe?.height;
    if (probe == null || !probe.isUniversal || height == null || height <= 0) {
      return sourceName;
    }
    final ext = dot > 0 ? sourceName.substring(dot) : '';
    return '$base [${height}p]$ext';
  }
  return '$base [${tierLabel(probe, tier)}].mp4';
}

/// Predicted encoded size from tier bitrates × duration (+2% container
/// overhead); null when the duration is unknown. Original = source size.
int? predictedSizeBytes(MediaProbe? probe, PublishTier tier, int sourceSize) {
  if (tier == PublishTier.original) return sourceSize;
  final duration = probe?.durationSeconds;
  if (duration == null || duration <= 0) return null;
  final spec = kTierSpecs[tier]!;
  final bps = (spec.videoKbps + spec.audioKbps) * 1000;
  return (duration * bps / 8 * 1.02).round();
}

/// Self-encryption chunk granularity on the network (max chunk size, with
/// a 3-chunk floor for any file).
const int kChunkBytes = 4 * 1024 * 1024;

int approxChunks(int bytes) => math.max(3, (bytes / kChunkBytes).ceil());

/// Approximate ANT cost for [bytes], scaled from one real estimate
/// (`refCostAtto` for `refChunks` chunks). Quotes are per-chunk, so the
/// per-chunk rate of the reference file carries over well enough for a
/// pre-pay preview; the network quotes live prices at upload time anyway.
BigInt approxCostAtto(int bytes, BigInt refCostAtto, int refChunks) {
  if (refChunks <= 0) return BigInt.zero;
  return refCostAtto * BigInt.from(approxChunks(bytes)) ~/ BigInt.from(refChunks);
}

/// A picked source file plus what probing learned about it.
class PublishSource {
  const PublishSource({
    required this.path,
    required this.name,
    required this.size,
    this.probe,
  });
  final String path;
  final String name;
  final int size;
  final MediaProbe? probe;

  List<PublishTier> get offered => offeredTiers(probe);
}

/// One encode(+upload) unit of the batch queue.
class PublishItem {
  PublishItem({
    required this.source,
    required this.tier,
    required this.outputName,
    required this.needsEncode,
    this.predictedBytes,
  });
  final PublishSource source;
  final PublishTier tier;
  final String outputName;
  final bool needsEncode;
  final int? predictedBytes;
}

/// The batch queue: for every file, each globally selected tier that
/// applies to it, files in pick order, best tier first.
List<PublishItem> buildQueue(
    List<PublishSource> sources, Set<PublishTier> selection) {
  final items = <PublishItem>[];
  for (final source in sources) {
    for (final tier in source.offered) {
      if (!selection.contains(tier)) continue;
      items.add(PublishItem(
        source: source,
        tier: tier,
        outputName: tierOutputName(source.name, tier, source.probe),
        needsEncode: tier != PublishTier.original,
        predictedBytes: predictedSizeBytes(source.probe, tier, source.size),
      ));
    }
  }
  return items;
}

/// ffmpeg arguments for encoding [input] to a tier (H.264 High 8-bit +
/// AAC stereo in a faststart MP4, first video/audio stream only, no
/// subtitle/data tracks). Downscales only — a source at or below the tier
/// height keeps its resolution (dimensions still snapped even for the
/// encoder). `-progress pipe:1` feeds the caller machine-readable
/// progress on stdout.
List<String> encodeArgs({
  required String input,
  required String output,
  required PublishTier tier,
  MediaProbe? probe,
}) {
  final spec = kTierSpecs[tier]!;
  final height = probe?.height;
  final needsScale = height != null && height > spec.height;
  final oddDims = !needsScale &&
      ((probe?.width ?? 0).isOdd || (probe?.height ?? 0).isOdd);
  return [
    '-y',
    '-i', input,
    '-map', '0:v:0',
    '-map', '0:a:0?',
    '-sn',
    '-dn',
    '-map_chapters', '-1',
    '-c:v', 'libx264',
    '-preset', 'medium',
    '-profile:v', 'high',
    '-pix_fmt', 'yuv420p',
    if (needsScale) ...['-vf', 'scale=-2:${spec.height}']
    else if (oddDims) ...['-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2'],
    '-b:v', '${spec.videoKbps}k',
    '-maxrate', '${(spec.videoKbps * 1.2).round()}k',
    '-bufsize', '${spec.videoKbps * 2}k',
    '-c:a', 'aac',
    '-b:a', '${spec.audioKbps}k',
    '-ac', '2',
    '-movflags', '+faststart',
    '-progress', 'pipe:1',
    '-nostats',
    '-loglevel', 'error',
    output,
  ];
}
