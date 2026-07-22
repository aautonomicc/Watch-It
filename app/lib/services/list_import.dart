import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import 'embedded_client.dart';

/// Import of media lists from a text file (local or fetched from
/// Autonomi). Two formats:
///
/// Single list — the first line is the list name:
///
/// ```
/// My Movie List
/// <64-hex xor address> Some Movie (2024) [1080p].mkv
/// <64-hex xor address> Another Movie (1999).mp4
/// ```
///
/// Multiple lists — a `ListName="..."` marker starts each list (quotes
/// optional, case-insensitive), so several lists can share one file:
///
/// ```
/// ListName="TV Series"
/// <64-hex xor address> Some Show S01E01.mkv
/// ListName="Movies"
/// <64-hex xor address> Some Movie (2024).mkv
/// ```
///
/// A `ListName=` marker is also honoured after a single-list header, so a
/// legacy file can grow extra lists by appending marker sections. Every
/// other non-empty line must be one `<xor address> <file name>` entry.
class ListImportException implements Exception {
  const ListImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One list parsed out of an import file.
class ParsedMediaList {
  const ParsedMediaList({required this.title, required this.entries});

  final String title;
  final List<MediaEntry> entries;
}

class ParsedMediaListFile {
  const ParsedMediaListFile({
    required this.lists,
    required this.skippedLines,
  });

  /// Lists in file order; sections repeating an earlier name (ignoring
  /// case) are folded into that list. Sections without any valid entry
  /// are dropped.
  final List<ParsedMediaList> lists;

  /// 1-based numbers of non-empty lines that were not valid
  /// `<xor address> <file name>` entries (reported, not fatal).
  final List<int> skippedLines;

  int get entryCount =>
      lists.fold(0, (sum, list) => sum + list.entries.length);
}

final RegExp _listNameMarker =
    RegExp(r'^ListName\s*=\s*(.+)$', caseSensitive: false);

/// Returns the list name when [line] is a `ListName=...` marker
/// (unquoting if needed), null otherwise.
String? _markerName(String line) {
  final match = _listNameMarker.firstMatch(line);
  if (match == null) return null;
  var name = match.group(1)!.trim();
  if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
    name = name.substring(1, name.length - 1).trim();
  }
  return name;
}

/// Parse a media-list file (single- or multi-list format, see the header
/// comment). Throws [ListImportException] when the content is not a
/// usable list; malformed individual lines are skipped and reported via
/// [ParsedMediaListFile.skippedLines].
ParsedMediaListFile parseMediaListFile(String content) {
  if (content.trim().isEmpty) {
    throw const ListImportException('The file is empty.');
  }
  final lines = content.split(RegExp(r'\r?\n'));
  final sections = <ParsedMediaList>[];
  final byLowerTitle = <String, ParsedMediaList>{};
  final skipped = <int>[];
  List<MediaEntry>? current;

  void startList(String title) {
    final existing = byLowerTitle[title.toLowerCase()];
    if (existing != null) {
      current = existing.entries;
      return;
    }
    final section = ParsedMediaList(title: title, entries: <MediaEntry>[]);
    sections.add(section);
    byLowerTitle[title.toLowerCase()] = section;
    current = section.entries;
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final marker = _markerName(line);
    if (marker != null) {
      if (marker.isEmpty) {
        skipped.add(i + 1);
        continue;
      }
      startList(marker);
      continue;
    }
    final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
    final address = match?.group(1) ?? '';
    if (match != null && looksLikeXorAddress(address)) {
      if (current == null) {
        throw const ListImportException(
            'The first line must be the list name, but this file starts '
            'with a media entry.');
      }
      current!.add(MediaEntry(
        name: match.group(2)!.trim(),
        address: address.toLowerCase().replaceFirst('0x', ''),
      ));
      continue;
    }
    if (current == null) {
      // Legacy single-list header: the first non-empty line names the
      // list. Only the first line gets this treatment.
      final firstWord =
          RegExp(r'^(\S+)').firstMatch(line)?.group(1) ?? '';
      if (looksLikeXorAddress(firstWord)) {
        throw const ListImportException(
            'The first line must be the list name, but this file starts '
            'with a media entry.');
      }
      startList(line);
    } else {
      skipped.add(i + 1);
    }
  }

  final lists =
      sections.where((section) => section.entries.isNotEmpty).toList();
  if (lists.isEmpty) {
    throw const ListImportException(
        'No "<xor address> <file name>" entries found below the list '
        'name.');
  }
  return ParsedMediaListFile(lists: lists, skippedLines: skipped);
}

/// Anything bigger than this is not a hand-written media list — refuse
/// early instead of pulling a movie into memory.
const int kMaxListFileBytes = 10 * 1024 * 1024;

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
