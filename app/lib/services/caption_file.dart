import 'dart:convert';
import 'dart:typed_data';

/// A local caption file is an explicit, per-playback attachment. No upload.
class CaptionFile {
  const CaptionFile(this.text, this.name, this.language);
  final String text;
  final String name;
  final String? language;

  static const maxBytes = 2 * 1024 * 1024;

  static CaptionFile parse(String name, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Caption size');
    }
    final lower = name.toLowerCase();
    if (!lower.endsWith('.srt') && !lower.endsWith('.vtt')) {
      throw const FormatException('Caption extension');
    }
    final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
    if (text.contains('\u0000') ||
        !RegExp(
          r'\d{2}:\d{2}[.,]\d{3}\s+-->\s+(?:\d{2}:)?\d{2}:\d{2}[.,]\d{3}',
        ).hasMatch(text)) {
      throw const FormatException('Missing timed cues');
    }
    if (lower.endsWith('.vtt') && !text.startsWith('WEBVTT')) {
      throw const FormatException('Missing WebVTT header');
    }
    final language = RegExp(
      r'\.([a-z]{2,3}(?:-[a-z]{2})?)\.(?:srt|vtt)$',
    ).firstMatch(lower)?.group(1);
    return CaptionFile(text, name, language);
  }
}
