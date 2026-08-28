import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Zip central-directory parsing + ranged member extraction for the
/// channel manifest delta import (channel_manifest_delta.dart): read the
/// directory from the tail of a remote zip, decide which members are
/// actually needed, and extract members from partial byte ranges without
/// ever holding the whole archive.
///
/// Deliberately conservative: anything unexpected (zip64, encryption,
/// overlapping member spans, signature/CRC mismatches) returns null and
/// the caller falls back to a whole-zip download — correctness never
/// depends on this parser, only savings do.

/// One central-directory entry, as needed for range planning.
class ZipCdEntry {
  const ZipCdEntry({
    required this.name,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;

  /// 0 = stored, 8 = deflate — anything else fails extraction.
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

/// The end-of-central-directory record's directory location.
class ZipEocd {
  const ZipEocd({
    required this.entryCount,
    required this.cdOffset,
    required this.cdSize,
  });

  final int entryCount;
  final int cdOffset;
  final int cdSize;
}

const int _eocdFixedSize = 22;
const int _cdEntryFixedSize = 46;
const int _localHeaderFixedSize = 30;

/// Locate the end-of-central-directory record in the last bytes of a
/// zip. [tail] holds the archive's suffix starting at absolute offset
/// [tailStart] of a [totalSize]-byte file. Null when absent or when the
/// archive uses features range extraction doesn't handle (zip64,
/// multi-disk).
ZipEocd? findZipEocd(Uint8List tail, int tailStart, int totalSize) {
  if (tailStart + tail.length != totalSize) return null;
  final bd = ByteData.sublistView(tail);
  // Search backwards: the record is trailed only by the archive comment.
  for (var i = tail.length - _eocdFixedSize; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) != 0x06054b50) continue;
    final commentLen = bd.getUint16(i + 20, Endian.little);
    if (i + _eocdFixedSize + commentLen != tail.length) continue;
    final diskEntries = bd.getUint16(i + 8, Endian.little);
    final totalEntries = bd.getUint16(i + 10, Endian.little);
    final cdSize = bd.getUint32(i + 12, Endian.little);
    final cdOffset = bd.getUint32(i + 16, Endian.little);
    if (diskEntries != totalEntries) return null; // multi-disk
    if (totalEntries == 0xFFFF || cdOffset == 0xFFFFFFFF) return null; // zip64
    if (cdOffset + cdSize != tailStart + i) return null;
    return ZipEocd(
        entryCount: totalEntries, cdOffset: cdOffset, cdSize: cdSize);
  }
  return null;
}

/// Parse [eocd.entryCount] central-directory entries from the directory
/// bytes. Null on any structural surprise.
List<ZipCdEntry>? parseZipCentralDirectory(Uint8List cd, ZipEocd eocd) {
  final bd = ByteData.sublistView(cd);
  final entries = <ZipCdEntry>[];
  var off = 0;
  for (var i = 0; i < eocd.entryCount; i++) {
    if (off + _cdEntryFixedSize > cd.length) return null;
    if (bd.getUint32(off, Endian.little) != 0x02014b50) return null;
    final flags = bd.getUint16(off + 8, Endian.little);
    if (flags & 0x0001 != 0) return null; // encrypted
    final method = bd.getUint16(off + 10, Endian.little);
    final crc = bd.getUint32(off + 16, Endian.little);
    final compressedSize = bd.getUint32(off + 20, Endian.little);
    final uncompressedSize = bd.getUint32(off + 24, Endian.little);
    final nameLen = bd.getUint16(off + 28, Endian.little);
    final extraLen = bd.getUint16(off + 30, Endian.little);
    final commentLen = bd.getUint16(off + 32, Endian.little);
    final lho = bd.getUint32(off + 42, Endian.little);
    if (compressedSize == 0xFFFFFFFF ||
        uncompressedSize == 0xFFFFFFFF ||
        lho == 0xFFFFFFFF) {
      return null; // zip64
    }
    if (off + _cdEntryFixedSize + nameLen > cd.length) return null;
    // Bundle members are written UTF-8 (archive's ZipEncoder); decode
    // leniently — a name that decodes oddly just won't match anything
    // and imports as an unknown member would.
    final name = utf8.decode(
        Uint8List.sublistView(cd, off + _cdEntryFixedSize,
            off + _cdEntryFixedSize + nameLen),
        allowMalformed: true);
    entries.add(ZipCdEntry(
      name: name,
      method: method,
      crc32: crc,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      localHeaderOffset: lho,
    ));
    off += _cdEntryFixedSize + nameLen + extraLen + commentLen;
  }
  if (off != cd.length) return null;
  return entries;
}

/// Absolute byte span `[start, end)` in the archive.
typedef ByteSpan = ({int start, int end});

/// The byte span of each member: from its local header to the next
/// member's local header (the last runs to the central directory), so a
/// span covers header + data + any trailing data descriptor. Null when
/// the offsets don't tile `[first, cdOffset)` cleanly.
Map<ZipCdEntry, ByteSpan>? zipMemberSpans(
    List<ZipCdEntry> entries, int cdOffset) {
  if (entries.isEmpty) return {};
  final sorted = [...entries]
    ..sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));
  final spans = <ZipCdEntry, ByteSpan>{};
  for (var i = 0; i < sorted.length; i++) {
    final start = sorted[i].localHeaderOffset;
    final end =
        i + 1 < sorted.length ? sorted[i + 1].localHeaderOffset : cdOffset;
    // A member is at least its local header plus the directory's
    // compressed size — overlapping or lying offsets fail the plan.
    if (end - start < _localHeaderFixedSize + sorted[i].compressedSize) {
      return null;
    }
    spans[sorted[i]] = (start: start, end: end);
  }
  return spans;
}

/// Merge sorted-or-not spans, joining neighbours closer than [gap]
/// bytes — fewer HTTP round trips for members that sit next to each
/// other, without forcing large skipped regions to download.
List<ByteSpan> coalesceSpans(Iterable<ByteSpan> spans, {int gap = 0}) {
  final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <ByteSpan>[];
  for (final s in sorted) {
    if (merged.isNotEmpty && s.start <= merged.last.end + gap) {
      if (s.end > merged.last.end) {
        merged.last = (start: merged.last.start, end: s.end);
      }
    } else {
      merged.add(s);
    }
  }
  return merged;
}

/// Extract one member from a fetched block that covers its span.
/// [block] holds archive bytes starting at absolute offset [blockStart].
/// Returns the decompressed member bytes, CRC-verified; null on any
/// mismatch.
Uint8List? extractZipMember(
    ZipCdEntry entry, ByteSpan span, Uint8List block, int blockStart) {
  final rel = span.start - blockStart;
  if (rel < 0 || span.end - blockStart > block.length) return null;
  final bd = ByteData.sublistView(block);
  if (rel + _localHeaderFixedSize > block.length) return null;
  if (bd.getUint32(rel, Endian.little) != 0x04034b50) return null;
  final nameLen = bd.getUint16(rel + 26, Endian.little);
  final extraLen = bd.getUint16(rel + 28, Endian.little);
  final dataStart = rel + _localHeaderFixedSize + nameLen + extraLen;
  if (dataStart + entry.compressedSize > span.end - blockStart) return null;
  final raw = Uint8List.sublistView(
      block, dataStart, dataStart + entry.compressedSize);
  final Uint8List data;
  switch (entry.method) {
    case 0:
      data = raw;
    case 8:
      try {
        data = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      } catch (_) {
        return null;
      }
    default:
      return null;
  }
  if (data.length != entry.uncompressedSize) return null;
  if (zipCrc32(data) != entry.crc32) return null;
  return data;
}

List<int>? _crcTable;

/// Plain CRC-32 (the zip polynomial) — verifies extracted members.
int zipCrc32(Uint8List data) {
  final table = _crcTable ??= List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}
