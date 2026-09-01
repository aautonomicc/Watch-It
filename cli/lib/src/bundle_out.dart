import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:watchit_naming/watchit_naming.dart';

/// Build a `.watch-list` bundle (spec v2, docs/BUNDLE-FORMAT.md) from
/// uploaded entries — the CLI-side twin of the app's
/// `bundle.dart buildBundle`. Custom (case-B) items ride exactly like the
/// app's Edit-details exports: `userEdited` metadata rows + posters that
/// gap-fill on import and are never overwritten by a later TMDB match.
class BundleOutEntry {
  BundleOutEntry({
    required this.name,
    required this.datamapBytes,
    this.custom = false,
    this.description,
    this.artBytes,
    this.customTitle,
    this.customYear,
    this.mediaType,
  });

  /// Final W@tch file name (member name = `<name>.datamap`).
  final String name;
  final Uint8List datamapBytes;
  final bool custom;
  final String? description;
  final List<int>? artBytes;
  final String? customTitle;
  final int? customYear;

  /// `music` — the declared direction for the app's future music support
  /// — or `movie`/`tv` (what the current parser would guess).
  final String? mediaType;
}

/// Same collision rule as the app's `datamapMemberName`: on a duplicate
/// base name a short content-hash suffix goes before `.datamap`.
String bundleMemberName(String entryName, String hash8, Set<String> taken) {
  var safe = entryName.replaceAll(RegExp(r'[/\\]'), '_').trim();
  if (safe.isEmpty) safe = 'entry';
  var candidate = '$safe.datamap';
  if (taken.contains(candidate.toLowerCase())) {
    candidate = '$safe.$hash8.datamap';
  }
  taken.add(candidate.toLowerCase());
  return candidate;
}

Uint8List buildWatchListBundle({
  required String listName,
  required List<BundleOutEntry> entries,
}) {
  final archive = Archive();
  final listText = StringBuffer()..writeln('ListName="$listName"');
  final taken = <String>{};
  final metadataRows = <Map<String, dynamic>>[];
  final now = DateTime.now().millisecondsSinceEpoch;

  for (final e in entries) {
    final hash8 =
        sha256.convert(e.datamapBytes).toString().substring(0, 8);
    final member = bundleMemberName(e.name, hash8, taken);
    archive.addFile(ArchiveFile.bytes('datamaps/$member', e.datamapBytes));
    listText.writeln(member);

    if (e.custom) {
      final parsed = parseMediaName(e.name);
      String? posterFile;
      if (e.artBytes != null) {
        final artHash =
            sha256.convert(e.artBytes!).toString().substring(0, 12);
        posterFile = 'user_cli_$artHash.jpg';
        archive.addFile(ArchiveFile.noCompress('posters/$posterFile',
            e.artBytes!.length, Uint8List.fromList(e.artBytes!)));
      }
      metadataRows.add({
        'lookupKey': parsed.lookupKey,
        'title': e.customTitle ?? parsed.title,
        'year': e.customYear ?? parsed.year,
        'overview': e.description,
        'category': null,
        'episodeLabel': parsed.isEpisode
            ? 'S${parsed.season.toString().padLeft(2, '0')}'
                'E${parsed.episode.toString().padLeft(2, '0')}'
            : null,
        'posterFile': posterFile,
        'mediaType': e.mediaType ??
            (parsed.isEpisode ? 'tv' : 'movie'),
        'tmdbId': null,
        'rating': null,
        'showOverview': null,
        'seasonOverview': null,
        'airDate': null,
        'stillFile': null,
        'showPosterFile': null,
        'userEdited': true,
        'fetchedAt': now,
      });
    }
  }

  archive.addFile(ArchiveFile.string('list.txt', listText.toString()));
  if (metadataRows.isNotEmpty) {
    archive.addFile(ArchiveFile.string(
      'metadata.json',
      jsonEncode({
        'version': 1,
        'entries': metadataRows,
      }),
    ));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void writeBundle(File out, String listName, List<BundleOutEntry> entries) {
  out.writeAsBytesSync(
      buildWatchListBundle(listName: listName, entries: entries),
      flush: true);
}
