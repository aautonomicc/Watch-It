import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import 'embedded_client.dart';

/// Import of a media list from a text file (local or fetched from
/// Autonomi). File format:
///
/// ```
/// My Movie List
/// <64-hex xor address> Some Movie (2024) [1080p].mkv
/// <64-hex xor address> Another Movie (1999).mp4
/// ```
///
/// The first line is the list name; every following non-empty line is one
/// `<xor address> <file name>` entry.
class ListImportException implements Exception {
  const ListImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ParsedMediaListFile {
  const ParsedMediaListFile({
    required this.title,
    required this.entries,
    required this.skippedLines,
  });

  final String title;
  final List<MediaEntry> entries;

  /// 1-based numbers of non-empty lines that were not valid
  /// `<xor address> <file name>` entries (reported, not fatal).
  final List<int> skippedLines;
}

/// Parse a media-list file. Throws [ListImportException] when the content
/// is not a usable list; malformed individual lines are skipped and
/// reported via [ParsedMediaListFile.skippedLines].
ParsedMediaListFile parseMediaListFile(String content) {
  if (content.trim().isEmpty) {
    throw const ListImportException('The file is empty.');
  }
  final lines = content.split(RegExp(r'\r?\n'));
  final title = lines.first.trim();
  final titleFirstWord = RegExp(r'^(\S+)').firstMatch(title)?.group(1) ?? '';
  if (title.isEmpty || looksLikeXorAddress(titleFirstWord)) {
    throw const ListImportException(
        'The first line must be the list name, but this file starts with '
        'a media entry.');
  }
  final entries = <MediaEntry>[];
  final skipped = <int>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
    final address = match?.group(1) ?? '';
    if (match == null || !looksLikeXorAddress(address)) {
      skipped.add(i + 1);
      continue;
    }
    entries.add(MediaEntry(
      name: match.group(2)!.trim(),
      address: address.toLowerCase().replaceFirst('0x', ''),
    ));
  }
  if (entries.isEmpty) {
    throw const ListImportException(
        'No "<xor address> <file name>" entries found below the list '
        'name.');
  }
  return ParsedMediaListFile(
    title: title,
    entries: entries,
    skippedLines: skipped,
  );
}

/// Anything bigger than this is not a hand-written media list — refuse
/// early instead of pulling a movie into memory.
const int kMaxListFileBytes = 4 * 1024 * 1024;

/// Download a list file from Autonomi via the embedded client and return
/// its text. [base] overrides the embedded server URL (tests).
Future<String> fetchListFromNetwork(String address, {String? base}) async {
  base ??= EmbeddedClient.baseUrl();
  if (base == null) {
    throw const ListImportException(
        'The network client is not available on this platform.');
  }
  final addr = address.trim().toLowerCase().replaceFirst('0x', '');
  if (!looksLikeXorAddress(addr)) {
    throw const ListImportException(
        'That is not a valid XOR address (expected 64 hex characters).');
  }
  final client = http.Client();
  try {
    final res = await client
        .send(http.Request('GET', Uri.parse('$base/xor/$addr')));
    if (res.statusCode != 200) {
      throw ListImportException(
          'Download failed (HTTP ${res.statusCode}).');
    }
    if ((res.contentLength ?? 0) > kMaxListFileBytes) {
      throw const ListImportException(
          'That file is too large to be a media list.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      bytes.add(chunk);
      if (bytes.length > kMaxListFileBytes) {
        throw const ListImportException(
            'That file is too large to be a media list.');
      }
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw const ListImportException(
          'That file is not a text file.');
    }
  } on ListImportException {
    rethrow;
  } catch (e) {
    throw ListImportException('Download failed: $e');
  } finally {
    client.close();
  }
}
