import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Sanitize one name component (artist, album, title …) for use in a
/// W@tch media file name. Lossy but filesystem-safe on every platform —
/// the embedded database id tag is the parser's source of truth, so
/// display names come from the database at runtime and nothing here needs
/// to be reversible (2026-09-01 sanitization decision):
///
/// - NFC unicode normalization (one byte sequence per accented name)
/// - `/` and `\` → `-`; `:` → ` -` (colon after a word keeps its rhythm)
/// - `<>"|?*` and control characters stripped (Windows-illegal)
/// - whitespace collapsed; trailing dots/spaces trimmed (Windows)
String sanitizeNamePart(String input) {
  var s = unorm.nfc(input);
  s = s.replaceAll(RegExp(r'[/\\]'), '-');
  s = s.replaceAll(': ', ' - ').replaceAll(':', ' -');
  s = s.replaceAll(RegExp(r'[<>"|?*]'), '');
  s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceFirst(RegExp(r'[. ]+$'), '');
  return s;
}

/// Truncate [s] to at most [maxBytes] UTF-8 bytes without splitting a
/// code point, trimming any dangling whitespace the cut leaves.
String truncateUtf8(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  final out = StringBuffer();
  var bytes = 0;
  for (final rune in s.runes) {
    final char = String.fromCharCode(rune);
    final len = utf8.encode(char).length;
    if (bytes + len > maxBytes) break;
    out.write(char);
    bytes += len;
  }
  return out.toString().trimRight();
}

/// Compose `<stem><suffix>` keeping the whole name within [maxBytes]
/// UTF-8 bytes (the common filesystem limit is 255 bytes per name). The
/// suffix — typically ` {mbid-…}.ext` — is always preserved intact; the
/// stem is truncated to fit. Throws [ArgumentError] if the suffix alone
/// exceeds the budget.
String fitFileName(String stem, String suffix, {int maxBytes = 255}) {
  final suffixLen = utf8.encode(suffix).length;
  if (suffixLen >= maxBytes) {
    throw ArgumentError('suffix alone exceeds $maxBytes bytes: $suffix');
  }
  return truncateUtf8(stem, maxBytes - suffixLen) + suffix;
}
