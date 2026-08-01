import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import 'embedded_client.dart';

/// Parser for the `list.txt` inside a `.watch-list` bundle (spec:
/// docs/BUNDLE-FORMAT.md). `ListName="..."` markers split lists (quotes
/// optional, case-insensitive); entry lines come in two forms:
///
/// - v2 (current): a line ending in `.datamap`, naming a bundle member —
///   the entry's address is derived from that member at import:
///
///   ```
///   ListName="TV Series"
///   Some Show S01E01 (2023) [1080p].mkv.datamap
///   ListName="Movies"
///   Some Movie (2024) [2160p].mp4.datamap
///   ```
///
/// - v1 (legacy, read-only): `<64-hex address> <file name>` — a v2
///   exporter never writes these; finding one marks the bundle as v1 and
///   the importer converts the entry at the border (its map comes from a
///   `rootmaps/` member or one import-time network fetch). Public
///   address == derived address, so the converted entry is identical to
///   a native one.
///
/// A bare first line is honoured as a single-list header (legacy files),
/// and `ListName=` markers may follow it.
class ListImportException implements Exception {
  const ListImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One list parsed out of an import file.
class ParsedMediaList {
  const ParsedMediaList({
    required this.title,
    required this.entries,
    this.datamapRefs = const [],
  });

  /// Mutable-list constructor used while parsing.
  ParsedMediaList._building(this.title)
      : entries = <MediaEntry>[],
        datamapRefs = <String>[];

  final String title;

  /// v1 hex-address entries — a bundle importer converts these at the
  /// border (never imported as-is).
  final List<MediaEntry> entries;

  /// v2 entry lines: `.datamap` member file names, resolved against the
  /// bundle's members at import.
  final List<String> datamapRefs;
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

  /// 1-based numbers of non-empty lines that were not valid entry lines
  /// (reported, not fatal).
  final List<int> skippedLines;

  /// True when any section carries a v1 `<64-hex address>` line — the
  /// bundle predates the datamap-first format and needs border
  /// conversion.
  bool get hasLegacyEntries =>
      lists.any((list) => list.entries.isNotEmpty);

  int get entryCount => lists.fold(
      0,
      (sum, list) =>
          sum + list.entries.length + list.datamapRefs.length);
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
  ParsedMediaList? current;

  void startList(String title) {
    final existing = byLowerTitle[title.toLowerCase()];
    if (existing != null) {
      current = existing;
      return;
    }
    final section = ParsedMediaList._building(title);
    sections.add(section);
    byLowerTitle[title.toLowerCase()] = section;
    current = section;
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
    // v1 legacy entry: `<64-hex address> <file name>`. Checked before the
    // `.datamap` suffix so a hex line can never be misread as a member
    // reference.
    final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
    final address = match?.group(1) ?? '';
    if (match != null && looksLikeXorAddress(address)) {
      if (current == null) {
        throw const ListImportException(
            'The first line must be the list name, but this file starts '
            'with a media entry.');
      }
      current!.entries.add(MediaEntry(
        name: match.group(2)!.trim(),
        address: address.toLowerCase().replaceFirst('0x', ''),
      ));
      continue;
    }
    // v2 entry: a `.datamap` member file name.
    if (line.toLowerCase().endsWith('.datamap') &&
        line.length > '.datamap'.length) {
      if (current == null) {
        throw const ListImportException(
            'The first line must be the list name, but this file starts '
            'with a media entry.');
      }
      current!.datamapRefs.add(line);
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

  final lists = sections
      .where((section) =>
          section.entries.isNotEmpty || section.datamapRefs.isNotEmpty)
      .toList();
  if (lists.isEmpty) {
    throw const ListImportException(
        'No entries found below the list name — expected '
        '"<file name>.datamap" lines.');
  }
  return ParsedMediaListFile(lists: lists, skippedLines: skipped);
}

/// Anything bigger than this is not a hand-written media list — refuse
/// early instead of pulling a movie into memory.
const int kMaxListFileBytes = 10 * 1024 * 1024;

/// Download a list (or bundle) file from Autonomi via the embedded
/// client and return its raw bytes — the caller sniffs zip-vs-text and
/// applies the tighter plain-text cap. [maxBytes] bounds the download
/// ([kMaxListFileBytes] for plain lists, the bundle cap for imports that
/// may be a `.watch-list`). [base] overrides the embedded server URL
/// (tests).
Future<Uint8List> fetchBytesFromNetwork(
  String address, {
  String? base,
  int maxBytes = kMaxListFileBytes,
}) async {
  base ??= EmbeddedClient.baseUrl();
  if (base == null) {
    throw const ListImportException(
        'The network client is not available on this platform.');
  }
  final addr = address.trim().toLowerCase().replaceFirst('0x', '');
  if (!looksLikeXorAddress(addr)) {
    throw const ListImportException(
        'That is not a valid address (expected 64 hex characters).');
  }
  final client = http.Client();
  try {
    // `/xor` streams from locally stored maps only (datamap-first model);
    // a shared bundle address is not in any list, so resolve its map over
    // the network first. This is one of the few remaining network-resolve
    // call sites (see docs/PLAN-datamap-privacy.md deprecation window).
    final resolve =
        await client.get(Uri.parse('$base/resolve/$addr'));
    if (resolve.statusCode != 200) {
      throw ListImportException(
          'Could not find that address on the network '
          '(HTTP ${resolve.statusCode}).');
    }
    final res = await client
        .send(http.Request('GET', Uri.parse('$base/xor/$addr')));
    if (res.statusCode != 200) {
      throw ListImportException(
          'Download failed (HTTP ${res.statusCode}).');
    }
    if ((res.contentLength ?? 0) > maxBytes) {
      throw const ListImportException(
          'That file is too large to be a media list.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        throw const ListImportException(
            'That file is too large to be a media list.');
      }
    }
    return bytes.takeBytes();
  } on ListImportException {
    rethrow;
  } catch (e) {
    throw ListImportException('Download failed: $e');
  } finally {
    client.close();
  }
}

/// Download a plain-text list file and return its text (pre-bundle API,
/// still used by tests and anything that wants text only).
Future<String> fetchListFromNetwork(String address, {String? base}) async {
  final bytes = await fetchBytesFromNetwork(address, base: base);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const ListImportException('That file is not a text file.');
  }
}
