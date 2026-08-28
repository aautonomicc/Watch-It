import 'dart:typed_data';

import 'bundle.dart';
import 'channels_api.dart';
import 'list_import.dart';
import 'zip_ranges.dart';

/// Delta-aware channel manifest fetch: instead of downloading the whole
/// manifest zip on every head update, read its central directory from
/// the tail, then fetch only the members this device still needs —
/// poster members whose file already sits in the posters directory are
/// skipped entirely (the import's gap-fill never writes over an existing
/// file, so their bytes would be thrown away anyway). Because
/// buildBundle writes posters as the last members, an updated channel's
/// unchanged posters occupy contiguous trailing chunks the ranged reads
/// never touch.
///
/// Anything unexpected — a core without range support answers 200 (the
/// whole zip is then used directly), any structural surprise returns
/// null — and the caller falls back to the plain whole-manifest fetch.
/// Savings are best-effort; correctness never depends on this path.

/// Issue one ranged read of the remote manifest.
typedef ManifestRangeFetch = Future<ManifestRangeResponse> Function(
    String range);

/// How much of the archive tail the first read grabs — comfortably holds
/// the end-of-central-directory record plus the directory itself for any
/// realistic channel (a directory entry is ~80 bytes per member).
const int kManifestTailBytes = 64 * 1024;

/// Members closer than this merge into one ranged read: fewer HTTP round
/// trips without forcing large skipped poster runs to download.
const int kManifestRangeMergeGap = 16 * 1024;

class ManifestDelta {
  const ManifestDelta({
    this.fullBytes,
    this.members,
    required this.totalSize,
    required this.bytesFetched,
    required this.postersSkipped,
  });

  /// The whole zip — a 200 answer or a manifest small enough that the
  /// tail read covered it. Exactly one of [fullBytes]/[members] is set.
  final Uint8List? fullBytes;

  /// Members assembled from ranged reads, skipped posters absent.
  final List<BundleZipMember>? members;

  final int totalSize;
  final int bytesFetched;
  final int postersSkipped;
}

/// The `posters/<base>` member base name when [name] is a sane poster
/// member, else null — mirrors the parser's hostile-name guard.
String? posterMemberBase(String name) {
  if (!name.startsWith('posters/')) return null;
  final base = name.substring('posters/'.length);
  if (base.isEmpty ||
      base.contains('/') ||
      base.contains('\\') ||
      base.contains('..')) {
    return null;
  }
  return base;
}

/// Fetch a manifest's members, skipping posters [havePoster] reports as
/// already on disk. Null means "couldn't plan a delta" — fall back to
/// the whole-manifest fetch. Throws [ListImportException] only for the
/// over-the-size-cap manifest a full fetch would refuse too.
Future<ManifestDelta?> fetchManifestMembersDelta({
  required ManifestRangeFetch fetch,
  required bool Function(String posterBaseName) havePoster,
  int maxBytes = kMaxBundleBytes,
  int tailBytes = kManifestTailBytes,
  int mergeGap = kManifestRangeMergeGap,
}) async {
  final tail = await fetch('bytes=-$tailBytes');
  if (tail.status == 200) {
    // No range support in the embedded core — the answer is the whole
    // manifest already, so just use it.
    if (tail.bytes.length > maxBytes) {
      throw const ListImportException(
          'That bundle is larger than the 200 MB limit.');
    }
    return ManifestDelta(
      fullBytes: tail.bytes,
      totalSize: tail.bytes.length,
      bytesFetched: tail.bytes.length,
      postersSkipped: 0,
    );
  }
  final total = tail.total;
  final tailStart = tail.start;
  if (total == null || tailStart == null) return null;
  if (total > maxBytes) {
    throw const ListImportException(
        'That bundle is larger than the 200 MB limit.');
  }
  if (tailStart + tail.bytes.length != total) return null;
  if (tailStart == 0) {
    // The tail read covered the whole manifest — nothing to skip.
    return ManifestDelta(
      fullBytes: tail.bytes,
      totalSize: total,
      bytesFetched: tail.bytes.length,
      postersSkipped: 0,
    );
  }
  var bytesFetched = tail.bytes.length;

  final eocd = findZipEocd(tail.bytes, tailStart, total);
  if (eocd == null) return null;
  Uint8List cd;
  if (eocd.cdOffset >= tailStart) {
    cd = Uint8List.sublistView(tail.bytes, eocd.cdOffset - tailStart,
        eocd.cdOffset - tailStart + eocd.cdSize);
  } else {
    final res = await fetch(
        'bytes=${eocd.cdOffset}-${eocd.cdOffset + eocd.cdSize - 1}');
    if (res.status != 206 ||
        res.start != eocd.cdOffset ||
        res.bytes.length != eocd.cdSize) {
      return null;
    }
    bytesFetched += res.bytes.length;
    cd = res.bytes;
  }
  final entries = parseZipCentralDirectory(cd, eocd);
  if (entries == null) return null;
  final spans = zipMemberSpans(entries, eocd.cdOffset);
  if (spans == null) return null;

  final needed = <ZipCdEntry>[];
  var postersSkipped = 0;
  for (final entry in entries) {
    // The parser caps a poster at kMaxPosterBytes; anything bigger is
    // dropped either way, so don't spend bytes on it.
    final posterBase = posterMemberBase(entry.name);
    if (posterBase != null &&
        (entry.uncompressedSize > kMaxPosterBytes || havePoster(posterBase))) {
      if (entry.uncompressedSize <= kMaxPosterBytes) postersSkipped++;
      continue;
    }
    needed.add(entry);
  }
  if (postersSkipped == 0) {
    // Nothing to save — the plain whole-manifest fetch is simpler and
    // covers the first import of a channel.
    return null;
  }

  final blocks = <({int start, Uint8List bytes})>[
    (start: tailStart, bytes: tail.bytes),
  ];
  final toFetch = coalesceSpans(
    [
      for (final entry in needed)
        // Anything the tail already covers is free.
        if (spans[entry]!.start < tailStart) spans[entry]!,
    ],
    gap: mergeGap,
  );
  for (final span in toFetch) {
    final end = span.end < tailStart ? span.end : tailStart;
    final res = await fetch('bytes=${span.start}-${end - 1}');
    if (res.status != 206 ||
        res.start != span.start ||
        res.bytes.length != end - span.start) {
      return null;
    }
    bytesFetched += res.bytes.length;
    blocks.add((start: span.start, bytes: res.bytes));
  }

  Uint8List? extract(ZipCdEntry entry) {
    final span = spans[entry]!;
    for (final block in blocks) {
      if (span.start >= block.start &&
          span.end <= block.start + block.bytes.length) {
        return extractZipMember(entry, span, block.bytes, block.start);
      }
    }
    // A span straddling the tail boundary: stitch the two pieces.
    for (final block in blocks) {
      if (span.start >= block.start &&
          span.start < block.start + block.bytes.length &&
          span.end > tailStart &&
          block.start + block.bytes.length == tailStart) {
        final joined = Uint8List(span.end - span.start);
        final head = block.bytes.sublist(span.start - block.start);
        joined.setAll(0, head);
        joined.setAll(
            head.length, tail.bytes.sublist(0, span.end - tailStart));
        return extractZipMember(entry, span, joined, span.start);
      }
    }
    return null;
  }

  final members = <BundleZipMember>[];
  for (final entry in needed) {
    final data = extract(entry);
    if (data == null) return null;
    members.add(BundleZipMember.bytes(entry.name, data));
  }
  return ManifestDelta(
    members: members,
    totalSize: total,
    bytesFetched: bytesFetched,
    postersSkipped: postersSkipped,
  );
}
