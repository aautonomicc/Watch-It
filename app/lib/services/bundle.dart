import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'datamap_import.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'list_import.dart';
import 'metadata.dart';
import 'watch_state.dart';

/// `.watch-list` bundle: a zip that carries the `.datamap` files of a
/// media library plus everything needed to enjoy it instantly on another
/// device — TMDB metadata rows, poster files, optionally watch history.
/// Format spec v2: docs/BUNDLE-FORMAT.md. `datamaps/<file name>.datamap`
/// members are raw ant-cli private-upload datamap files (also accepted at
/// the zip root, so a hand-made `zip lib.watch-list *.datamap` is a valid
/// bundle); the optional `list.txt` assigns members to named lists.
/// v1 bundles (hex-address `list.txt` lines + `rootmaps/` members) no
/// longer import — the network map fetch their conversion needed was
/// deleted in release 3 of the datamap-first plan; re-export from a
/// 0.1.0-alpha.40+ install instead.

/// Bundles bigger than this are refused outright.
const int kMaxBundleBytes = 200 * 1024 * 1024;

/// Per-member decompressed-size sanity limits (zip-bomb guard) — checked
/// against the zip directory's declared size before extraction.
const int kMaxMetadataJsonBytes = 50 * 1024 * 1024;
const int kMaxLibraryJsonBytes = 5 * 1024 * 1024;
const int kMaxHistoryJsonBytes = 20 * 1024 * 1024;
const int kMaxPosterBytes = 10 * 1024 * 1024;
const int kMaxRootMapBytes = 32 * 1024 * 1024;

/// TMDB's required attribution, shown in Settings → About and carried in
/// every exported bundle's metadata.json.
const String kTmdbAttributionNotice =
    'This product uses the TMDB API but is not endorsed or certified by '
    'TMDB.';

/// Zip magic sniff — import routing never looks at the file extension.
bool looksLikeZip(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;

/// The user cancelled a network bundle fetch — flow control, not an
/// error; the import aborts silently.
class BundleFetchCancelled implements Exception {
  const BundleFetchCancelled();
}

/// Fetch a `.watch-list` bundle stored on the network from its
/// `.datamap` file: store the map via the embedded client (which also
/// derives the bundle's address and total size offline), then download
/// the bundle bytes over `GET /xor/{addr}`. [onProgress] reports
/// (received, total) bytes per chunk; [isCancelled] is polled per chunk
/// and throws [BundleFetchCancelled] when it turns true. Throws
/// [ListImportException] with a user-facing message on any failure.
Future<Uint8List> fetchBundleByDatamap(
  Uint8List datamapBytes, {
  String? base,
  void Function(int received, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  base ??= EmbeddedClient.baseUrl();
  if (base == null) {
    throw const ListImportException(
        'The built-in Autonomi client is not available on this platform.');
  }
  final imported = await importDatamapBytes(datamapBytes, base: base);
  if (imported.size > kMaxBundleBytes) {
    throw ListImportException(
        'That data map points at a ${imported.size ~/ (1024 * 1024)} MB '
        'file — too large to be a .watch-list bundle.');
  }
  final client = http.Client();
  try {
    final res = await client
        .send(http.Request('GET', Uri.parse('$base/xor/${imported.address}')));
    if (res.statusCode != 200) {
      throw const ListImportException(
          'The bundle could not be downloaded — check the connection and '
          'that the bundle is still on the network.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      if (isCancelled?.call() ?? false) throw const BundleFetchCancelled();
      builder.add(chunk);
      if (builder.length > kMaxBundleBytes) {
        throw const ListImportException(
            'That bundle is larger than the 200 MB limit.');
      }
      onProgress?.call(builder.length, imported.size);
    }
    return builder.takeBytes();
  } on ListImportException {
    rethrow;
  } on BundleFetchCancelled {
    rethrow;
  } catch (e) {
    throw ListImportException('Bundle download failed: $e');
  } finally {
    client.close();
  }
}

/// One history.json row's playback fields — the address they belong to
/// is only known once the member's data map has been imported.
typedef BundleHistoryRow = ({
  int positionMs,
  int durationMs,
  bool completed,
  int updatedAt,
});

/// One bundle, parsed and size-checked but not yet applied.
class ParsedBundle {
  const ParsedBundle({
    required this.listText,
    required this.datamapMembers,
    required this.metadataRows,
    required this.posters,
    required this.libraryPrefs,
    this.historyByMember = const {},
  });

  /// The inner `list.txt` — optional since spec v2; null means every
  /// datamap member goes to the importer's default list.
  final String? listText;

  /// `.datamap` member bytes by member file name (`datamaps/` directory
  /// or zip root, base name only).
  final Map<String, Uint8List> datamapMembers;

  /// metadata.json rows (validated maps), keyed by lookupKey.
  final Map<String, Map<String, dynamic>> metadataRows;

  /// Poster file bytes by (sanitized) file name.
  final Map<String, Uint8List> posters;

  /// library.json per-list prefs by lowercased title.
  final Map<String, ({bool enabled, int position})> libraryPrefs;

  /// history.json rows keyed by `.datamap` member name (spec v2); their
  /// addresses resolve through [BundleImportResult.addressByMember] at
  /// seed time, so history never carries a bare address. Legacy spec-v1
  /// address-keyed rows are ignored on read since alpha.46 (test-group
  /// decision — re-export on alpha.45+ restores dropped history).
  final Map<String, BundleHistoryRow> historyByMember;

  int get historyCount => historyByMember.length;

  bool get hasSeedableExtras =>
      metadataRows.isNotEmpty || posters.isNotEmpty || historyCount > 0;
}

/// What [seedBundle] actually applied (for the import snackbar).
class BundleSeedSummary {
  int metadataSeeded = 0;
  int postersSeeded = 0;
  int historyMerged = 0;
}

String _normalizeAddr(String address) =>
    address.trim().toLowerCase().replaceFirst('0x', '');

Future<Directory> _defaultPostersDir() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/posters');
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

/// Options from the export dialog.
class BundleExportOptions {
  const BundleExportOptions({
    required this.includeHistory,
    this.includeLibrary = false,
  });

  /// Default OFF — shared lists shouldn't leak viewing habits; a
  /// migration backup opts in explicitly.
  final bool includeHistory;

  /// Library export only: add library.json (per-list order/visibility).
  final bool includeLibrary;
}

class BundleBuildResult {
  const BundleBuildResult({
    required this.bytes,
    required this.entriesIncluded,
    required this.entriesMissingMap,
  });

  final Uint8List bytes;

  /// Entries whose `.datamap` member made it into the bundle.
  final int entriesIncluded;

  /// Entries skipped because their map is not in the local store (a
  /// "map missing — re-import" entry). They are left out of `list.txt`
  /// too, so the bundle stays internally consistent.
  final int entriesMissingMap;
}

/// The `.datamap` member name for an entry: its media file name (path
/// separators neutralized) plus `.datamap`. On a collision with an
/// already-taken name, a short derived-address suffix goes before the
/// extension — same trick as download file names.
String datamapMemberName(
    String entryName, String address, Set<String> taken) {
  var safe = entryName.replaceAll(RegExp(r'[/\\]'), '_').trim();
  if (safe.isEmpty) safe = 'entry';
  var candidate = '$safe.datamap';
  if (taken.contains(candidate.toLowerCase())) {
    candidate = '$safe.${address.substring(0, 8)}.datamap';
  }
  taken.add(candidate.toLowerCase());
  return candidate;
}

/// Assemble a `.watch-list` bundle (spec v2) for [lists]. Every entry's
/// root map is in the local store by construction (maps arrive at import
/// time), so members are written straight from `GET /datamap/<addr>`;
/// the rare "map missing" entry is skipped and counted. Metadata and
/// posters are whatever is cached locally right now.
Future<BundleBuildResult> buildBundle(
  List<MediaList> lists,
  BundleExportOptions options, {
  String? base,
  Future<Directory> Function()? postersDirProvider,
}) async {
  base ??= EmbeddedClient.baseUrl();
  final archive = Archive();

  // datamaps/ members + list.txt, built together so the list only names
  // members that exist. One member may be referenced by several lists
  // (same address → first member name wins).
  final listText = StringBuffer();
  final memberNames = <String>{};
  final memberByAddr = <String, String>{};
  var included = 0, missingMap = 0;
  final httpClient = HttpClient();
  try {
    for (final list in lists) {
      listText.writeln('ListName="${list.title}"');
      for (final e in list.entries) {
        final addr = _normalizeAddr(e.address);
        var member = memberByAddr[addr];
        if (member == null) {
          Uint8List? bytes;
          if (base != null) {
            try {
              final req = await httpClient
                  .getUrl(Uri.parse('$base/datamap/$addr'));
              final res = await req.close();
              final builder = BytesBuilder(copy: false);
              await res.forEach(builder.add);
              if (res.statusCode == 200) bytes = builder.takeBytes();
            } catch (_) {}
          }
          if (bytes == null) {
            missingMap++;
            continue;
          }
          member = datamapMemberName(e.name, addr, memberNames);
          memberByAddr[addr] = member;
          archive.addFile(ArchiveFile.bytes('datamaps/$member', bytes));
          included++;
        }
        listText.writeln(member);
      }
    }
  } finally {
    httpClient.close(force: true);
  }
  archive.addFile(ArchiveFile.string('list.txt', listText.toString()));

  final entries = [for (final list in lists) ...list.entries];

  // metadata.json + posters/ — cached rows for the bundled entries.
  final keys = <String>{
    for (final e in entries) parseMediaName(e.name).lookupKey,
  };
  final db = await LibraryStore.database();
  final rows = keys.isEmpty
      ? <MetadataCacheRow>[]
      : await (db.select(db.metadataCache)
            ..where((t) => t.lookupKey.isIn(keys) & t.found.equals(true)))
          .get();
  final posterFiles = <String>{};
  final metadataEntries = <Map<String, dynamic>>[];
  for (final row in rows) {
    metadataEntries.add({
      'lookupKey': row.lookupKey,
      'title': row.title,
      'year': row.year,
      'overview': row.overview,
      'category': row.category,
      'episodeLabel': row.episodeLabel,
      'posterFile': row.posterFile,
      'mediaType': row.mediaType,
      'tmdbId': row.tmdbId,
      'rating': row.rating,
      'showOverview': row.showOverview,
      'seasonOverview': row.seasonOverview,
      'airDate': row.airDate,
      'stillFile': row.stillFile,
      'showPosterFile': row.showPosterFile,
    });
    posterFiles.addAll([
      if (row.posterFile != null) row.posterFile!,
      if (row.stillFile != null) row.stillFile!,
      if (row.showPosterFile != null) row.showPosterFile!,
    ]);
  }
  if (metadataEntries.isNotEmpty) {
    archive.addFile(ArchiveFile.string(
      'metadata.json',
      jsonEncode({
        'version': 1,
        'attribution': kTmdbAttributionNotice,
        'entries': metadataEntries,
      }),
    ));
  }
  final postersDir = await (postersDirProvider ?? _defaultPostersDir)();
  for (final name in posterFiles) {
    final file = File('${postersDir.path}/$name');
    if (!file.existsSync()) continue;
    // JPGs don't deflate — store them uncompressed.
    archive.addFile(
        ArchiveFile.noCompress('posters/$name', file.lengthSync(),
            await file.readAsBytes()));
  }

  if (options.includeLibrary) {
    archive.addFile(ArchiveFile.string(
      'library.json',
      jsonEncode({
        'version': 1,
        'lists': [
          for (final (position, list) in lists.indexed)
            {
              'title': list.title,
              'enabled': list.enabled,
              'position': position,
            },
        ],
      }),
    ));
  }

  // History rows are keyed by `.datamap` member name (spec v2), never by
  // address — an entry whose map is missing has no member, so its state
  // stays out rather than leaking a bare address.
  if (options.includeHistory && memberByAddr.isNotEmpty) {
    final states = await (db.select(db.watchStates)
          ..where((t) => t.address.isIn(memberByAddr.keys)))
        .get();
    if (states.isNotEmpty) {
      archive.addFile(ArchiveFile.string(
        'history.json',
        jsonEncode({
          'version': 2,
          'entries': [
            for (final s in states)
              {
                'member': memberByAddr[s.address],
                'positionMs': s.positionMs,
                'durationMs': s.durationMs,
                'completed': s.completed,
                'updatedAt': s.updatedAt,
              },
          ],
        }),
      ));
    }
  }

  final bytes = ZipEncoder().encode(archive);
  return BundleBuildResult(
    bytes: Uint8List.fromList(bytes),
    entriesIncluded: included,
    entriesMissingMap: missingMap,
  );
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// A safe `.datamap` member base name: no path separators or `..`
/// segments (a hostile member must not escape anywhere), ends in
/// `.datamap` with something before it.
String? _datamapBaseName(String memberName) {
  final base = memberName.startsWith('datamaps/')
      ? memberName.substring('datamaps/'.length)
      : memberName;
  if (base.isEmpty ||
      base.contains('/') ||
      base.contains('\\') ||
      base.contains('..')) {
    return null;
  }
  final lower = base.toLowerCase();
  if (!lower.endsWith('.datamap') || base.length == '.datamap'.length) {
    return null;
  }
  return base;
}

/// Decode and size-check a bundle. Every member is optional — a zip of
/// nothing but `.datamap` files is a valid bundle — but a bundle with
/// neither `list.txt` nor datamap members has nothing to import and
/// throws. Malformed or oversized optional members are dropped (import
/// never fails on extras); a decompressed-size lie big enough to matter
/// throws.
ParsedBundle parseBundle(Uint8List bytes) {
  if (bytes.length > kMaxBundleBytes) {
    throw const ListImportException(
        'That bundle is larger than the 200 MB limit.');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    throw const ListImportException(
        'That file looks like a zip archive but could not be read as a '
        '.watch-list bundle.');
  }

  String? listText;
  final datamapMembers = <String, Uint8List>{};
  final metadataRows = <String, Map<String, dynamic>>{};
  final posters = <String, Uint8List>{};
  final libraryPrefs = <String, ({bool enabled, int position})>{};
  final historyByMember = <String, BundleHistoryRow>{};

  Uint8List? readCapped(ArchiveFile file, int cap) {
    if (file.size > cap) return null;
    final data = file.readBytes();
    if (data == null || data.length > cap) return null;
    return data;
  }

  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    switch (name) {
      case 'list.txt':
        final data = readCapped(file, kMaxListFileBytes);
        if (data == null) {
          throw const ListImportException(
              'The list inside this bundle is too large to be a media '
              'list.');
        }
        try {
          listText = utf8.decode(data);
        } on FormatException {
          throw const ListImportException(
              'The list inside this bundle is not a text file.');
        }
      case 'metadata.json':
        final data = readCapped(file, kMaxMetadataJsonBytes);
        if (data == null) continue;
        try {
          final decoded = jsonDecode(utf8.decode(data));
          final entries = (decoded as Map<String, dynamic>)['entries'];
          for (final raw in entries as List<dynamic>) {
            final row = raw as Map<String, dynamic>;
            final key = row['lookupKey'];
            if (key is String && key.isNotEmpty) {
              metadataRows[key] = row;
            }
          }
        } catch (_) {
          // Malformed metadata: the list still imports.
        }
      case 'library.json':
        final data = readCapped(file, kMaxLibraryJsonBytes);
        if (data == null) continue;
        try {
          final decoded = jsonDecode(utf8.decode(data));
          final lists = (decoded as Map<String, dynamic>)['lists'];
          for (final raw in lists as List<dynamic>) {
            final row = raw as Map<String, dynamic>;
            final title = row['title'];
            if (title is String && title.isNotEmpty) {
              libraryPrefs[title.toLowerCase()] = (
                enabled: row['enabled'] as bool? ?? true,
                position: row['position'] as int? ?? 1 << 30,
              );
            }
          }
        } catch (_) {}
      case 'history.json':
        final data = readCapped(file, kMaxHistoryJsonBytes);
        if (data == null) continue;
        try {
          final decoded = jsonDecode(utf8.decode(data));
          final entries = (decoded as Map<String, dynamic>)['entries'];
          for (final raw in entries as List<dynamic>) {
            final row = raw as Map<String, dynamic>;
            // Rows name their `.datamap` member (spec v2); the address
            // comes from importing that member, never from the file.
            // Rows without a member — including spec-v1 address-keyed
            // ones — are silently skipped.
            final member = row['member'];
            if (member is String && member.isNotEmpty) {
              historyByMember[member] = (
                positionMs: row['positionMs'] as int? ?? 0,
                durationMs: row['durationMs'] as int? ?? 0,
                completed: row['completed'] as bool? ?? false,
                updatedAt: row['updatedAt'] as int? ?? 0,
              );
            }
          }
        } catch (_) {}
      default:
        // `.datamap` members: `datamaps/` directory canonically, zip root
        // also accepted (the hand-made `zip lib.watch-list *.datamap`
        // floor). The directory form wins on a duplicate base name.
        final datamapBase = _datamapBaseName(name);
        if (datamapBase != null) {
          final data = readCapped(file, kMaxRootMapBytes);
          if (data != null &&
              (name.startsWith('datamaps/') ||
                  !datamapMembers.containsKey(datamapBase))) {
            datamapMembers[datamapBase] = data;
          }
          continue;
        }
        if (name.startsWith('posters/')) {
          // Basename only — a hostile member name must not escape the
          // posters directory.
          final base = name.substring('posters/'.length);
          if (base.isEmpty ||
              base.contains('/') ||
              base.contains('\\') ||
              base.contains('..')) {
            continue;
          }
          final data = readCapped(file, kMaxPosterBytes);
          if (data != null) posters[base] = data;
        }
      // Unknown members are ignored (forward compatibility).
    }
  }

  if (listText == null && datamapMembers.isEmpty) {
    throw const ListImportException(
        'This bundle has no .datamap files or list.txt inside — nothing '
        'to import.');
  }
  return ParsedBundle(
    listText: listText,
    datamapMembers: datamapMembers,
    metadataRows: metadataRows,
    posters: posters,
    libraryPrefs: libraryPrefs,
    historyByMember: historyByMember,
  );
}

/// Lists ready to merge into the library after [importBundleEntries]
/// turned every member and line into datamap-backed entries, plus the
/// counts the import snackbar reports.
class BundleImportResult {
  BundleImportResult({
    required this.lists,
    required this.datamapsImported,
    required this.datamapsInvalid,
    required this.refsMissing,
    required this.skippedLines,
    this.addressByMember = const {},
  });

  /// Final lists (title + entries; every entry's map is now in the local
  /// store). Lists that ended up empty are dropped.
  final List<ParsedMediaList> lists;

  /// `.datamap` members imported (address derived, map stored).
  final int datamapsImported;

  /// Members that were not parseable data maps (skipped, warned).
  final int datamapsInvalid;

  /// list.txt lines referencing a member the bundle doesn't carry.
  final int refsMissing;

  /// Invalid list.txt lines (from the parser), including v1 hex-address
  /// entries — those no longer import.
  final List<int> skippedLines;

  /// Member name → derived (normalized) address for every imported
  /// member — what [seedBundle] uses to resolve member-keyed history.
  final Map<String, String> addressByMember;

  int get entryCount =>
      lists.fold(0, (sum, list) => sum + list.entries.length);
}

/// Turn a parsed bundle into importable lists. Spec-v2 members become
/// entries by deriving each `.datamap`'s address offline in the embedded
/// client; members no list references (or all of them, when there is no
/// `list.txt`) go to [defaultListTitle]. Throws [ListImportException]
/// only when nothing at all is importable.
Future<BundleImportResult> importBundleEntries(
  ParsedBundle bundle, {
  String? base,
  String defaultListTitle = 'Imported',
}) async {
  base ??= EmbeddedClient.baseUrl();

  // Every member becomes a stored map + prospective entry first.
  final entriesByMember = <String, MediaEntry>{};
  var invalid = 0;
  for (final member in bundle.datamapMembers.entries) {
    try {
      entriesByMember[member.key] = await entryFromDatamapFile(
        member.key,
        member.value,
        base: base,
      );
    } on ListImportException {
      invalid++;
    }
  }

  ParsedMediaListFile? parsed;
  if (bundle.listText != null) {
    try {
      parsed = parseMediaListFile(bundle.listText!);
    } on ListImportException {
      // A malformed list.txt degrades to member-only import when the
      // members can stand alone; with no members there is nothing left.
      if (entriesByMember.isEmpty) rethrow;
    }
  }

  final lists = <ParsedMediaList>[];
  final referenced = <String>{};
  var refsMissing = 0;
  for (final section in parsed?.lists ?? const <ParsedMediaList>[]) {
    final entries = <MediaEntry>[];
    for (final ref in section.datamapRefs) {
      final entry = entriesByMember[ref];
      if (entry == null) {
        refsMissing++;
        continue;
      }
      referenced.add(ref);
      entries.add(entry);
    }
    if (entries.isNotEmpty) {
      lists.add(ParsedMediaList(title: section.title, entries: entries));
    }
  }

  // Members no list claimed: the default list (named after the bundle
  // file, or what the import prompt chose).
  final unclaimed = [
    for (final member in entriesByMember.entries)
      if (!referenced.contains(member.key)) member.value,
  ];
  if (unclaimed.isNotEmpty) {
    final i = lists.indexWhere(
        (l) => l.title.toLowerCase() == defaultListTitle.toLowerCase());
    if (i >= 0) {
      lists[i] = ParsedMediaList(
        title: lists[i].title,
        entries: [...lists[i].entries, ...unclaimed],
      );
    } else {
      lists.add(
          ParsedMediaList(title: defaultListTitle, entries: unclaimed));
    }
  }

  if (lists.isEmpty) {
    throw const ListImportException(
        'Nothing could be imported from this bundle.');
  }
  return BundleImportResult(
    lists: lists,
    datamapsImported: entriesByMember.length,
    datamapsInvalid: invalid,
    refsMissing: refsMissing,
    skippedLines: parsed?.skippedLines ?? const [],
    addressByMember: {
      for (final e in entriesByMember.entries)
        e.key: _normalizeAddr(e.value.address),
    },
  );
}

/// Apply library.json to the lists this import just created (never to
/// pre-existing lists): set their home-screen visibility and order them
/// among themselves by the bundled position. A fresh-device import hits
/// an empty library, so the full home state restores anyway.
List<MediaList> applyLibraryPrefs(
  List<MediaList> lists,
  Set<String> createdIds,
  Map<String, ({bool enabled, int position})> prefs,
) {
  if (prefs.isEmpty || createdIds.isEmpty) return lists;
  final result = <MediaList>[];
  final created = <MediaList>[];
  for (final list in lists) {
    if (createdIds.contains(list.id)) {
      final pref = prefs[list.title.toLowerCase()];
      created.add(
          pref == null ? list : list.copyWith(enabled: pref.enabled));
    } else {
      result.add(list);
    }
  }
  // Created lists were appended at the tail; keep them there but in the
  // bundle's order (stable for titles the bundle doesn't know).
  final order = <String, int>{
    for (final (i, list) in created.indexed) list.id: i,
  };
  created.sort((a, b) {
    final pa = prefs[a.title.toLowerCase()]?.position ?? 1 << 30;
    final pb = prefs[b.title.toLowerCase()]?.position ?? 1 << 30;
    return pa != pb ? pa - pb : order[a.id]! - order[b.id]!;
  });
  return result..addAll(created);
}

/// Seed the local caches from a parsed bundle. Existing local state
/// always wins — only gaps are filled (metadata rows and poster files
/// that don't exist locally), and history merges newer-updatedAt-wins.
/// Data maps are not seeded here: `.datamap` members are handled by
/// [importBundleEntries], where they define the entries themselves.
/// [importHistory] comes from the import-side
/// options dialog — declined history is skipped entirely, as if the
/// bundle never carried it. Member-keyed (spec v2) history rows resolve
/// their addresses through [addressByMember] (from
/// [BundleImportResult]); rows naming a member that didn't import are
/// dropped.
Future<BundleSeedSummary> seedBundle(
  ParsedBundle bundle, {
  bool importHistory = true,
  Map<String, String> addressByMember = const {},
  Future<Directory> Function()? postersDirProvider,
}) async {
  final summary = BundleSeedSummary();
  final (metadataSeeded, postersSeeded) = await seedMetadataGapFill(
      bundle.metadataRows, bundle.posters,
      postersDirProvider: postersDirProvider);
  summary.metadataSeeded = metadataSeeded;
  summary.postersSeeded = postersSeeded;

  // Watch history: newer-updatedAt-wins, never regresses local progress.
  if (importHistory) {
    final states = <WatchState>[
      for (final e in bundle.historyByMember.entries)
        if (addressByMember[e.key] != null)
          WatchState(
            address: addressByMember[e.key]!,
            positionMs: e.value.positionMs,
            durationMs: e.value.durationMs,
            completed: e.value.completed,
            updatedAt: e.value.updatedAt,
          ),
    ];
    if (states.isNotEmpty) {
      summary.historyMerged =
          await WatchStateStore.instance.mergeAll(states);
    }
  }

  return summary;
}

/// Gap-fill the metadata cache and posters directory: rows whose
/// lookupKey already exists and poster files already on disk always win.
/// Shared by bundle import ([seedBundle]) and the first-run catalog
/// seeder (metadata_seeder.dart). Returns (rowsSeeded, filesSeeded).
Future<(int, int)> seedMetadataGapFill(
  Map<String, Map<String, dynamic>> metadataRows,
  Map<String, Uint8List> posters, {
  Future<Directory> Function()? postersDirProvider,
}) async {
  var metadataSeeded = 0;
  var postersSeeded = 0;
  final db = await LibraryStore.database();
  final now = DateTime.now().millisecondsSinceEpoch;

  // Metadata rows: fill gaps only.
  if (metadataRows.isNotEmpty) {
    final existing = await (db.selectOnly(db.metadataCache)
          ..addColumns([db.metadataCache.lookupKey])
          ..where(db.metadataCache.lookupKey
              .isIn(metadataRows.keys.toList())))
        .map((row) => row.read(db.metadataCache.lookupKey)!)
        .get();
    final have = existing.toSet();
    for (final entry in metadataRows.entries) {
      if (have.contains(entry.key)) continue;
      final row = entry.value;
      try {
        await db.into(db.metadataCache).insert(
              MetadataCacheCompanion.insert(
                lookupKey: entry.key,
                found: true,
                title: Value(row['title'] as String?),
                year: Value(row['year'] as int?),
                overview: Value(row['overview'] as String?),
                category: Value(row['category'] as String?),
                episodeLabel: Value(row['episodeLabel'] as String?),
                posterFile: Value(row['posterFile'] as String?),
                mediaType: Value(row['mediaType'] as String?),
                tmdbId: Value(row['tmdbId'] as int?),
                fetchedAt: now,
                rating: Value((row['rating'] as num?)?.toDouble()),
                showOverview: Value(row['showOverview'] as String?),
                seasonOverview: Value(row['seasonOverview'] as String?),
                airDate: Value(row['airDate'] as String?),
                stillFile: Value(row['stillFile'] as String?),
                showPosterFile: Value(row['showPosterFile'] as String?),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        metadataSeeded++;
      } catch (_) {
        // A malformed row (wrong types) skips, the rest still seed.
      }
    }
  }

  // Poster files: existing files win.
  if (posters.isNotEmpty) {
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    await dir.create(recursive: true);
    for (final entry in posters.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (file.existsSync()) continue;
      try {
        await file.writeAsBytes(entry.value, flush: true);
        postersSeeded++;
      } catch (_) {}
    }
  }

  return (metadataSeeded, postersSeeded);
}
