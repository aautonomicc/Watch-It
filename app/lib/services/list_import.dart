import '../models/media_list.dart';

/// Parser for the `list.txt` inside a `.watch-list` bundle (spec:
/// docs/BUNDLE-FORMAT.md). `ListName="..."` markers split lists (quotes
/// optional, case-insensitive); an entry line ends in `.datamap` and
/// names a bundle member — the entry's address is derived from that
/// member at import:
///
/// ```
/// ListName="TV Series"
/// Some Show S01E01 (2023) [1080p].mkv.datamap
/// ListName="Movies"
/// Some Movie (2024) [2160p].mp4.datamap
/// ```
///
/// v1 `<64-hex address> <file name>` lines no longer import (the
/// network map fetch they needed was deleted with release 3 of the
/// datamap-first plan) — they are skipped, and a file containing only
/// such lines gets a "re-export from a newer Watch-It" error.
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

  /// Final imported entries — filled by the bundle importer when it
  /// resolves [datamapRefs] against the bundle members (the list.txt
  /// parser itself never produces any).
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
  var sawLegacyLine = false;
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
    // v1 legacy entry: `<64-hex address> <file name>`. No longer
    // importable (border conversion needed a network map fetch, deleted
    // in release 3) — skipped, but remembered so an all-v1 file gets a
    // pointed error instead of a generic one. Checked before the
    // `.datamap` suffix so a hex line can never be misread as a member
    // reference.
    final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
    final address = match?.group(1) ?? '';
    if (match != null && looksLikeXorAddress(address)) {
      sawLegacyLine = true;
      skipped.add(i + 1);
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
        sawLegacyLine = true;
        skipped.add(i + 1);
        continue;
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
    if (sawLegacyLine) {
      throw const ListImportException(
          'This list uses the old public-address format, which can no '
          'longer be imported. Re-export it as a bundle from Watch-It '
          '0.1.0-alpha.40 or later.');
    }
    throw const ListImportException(
        'No entries found below the list name — expected '
        '"<file name>.datamap" lines.');
  }
  return ParsedMediaListFile(lists: lists, skippedLines: skipped);
}

/// Anything bigger than this is not a hand-written media list — refuse
/// early instead of pulling a movie into memory.
const int kMaxListFileBytes = 10 * 1024 * 1024;
