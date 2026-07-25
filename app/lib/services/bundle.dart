import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'list_import.dart';
import 'metadata.dart';
import 'watch_state.dart';

/// `.watch-list` bundle: a zip that carries a media list plus everything
/// needed to enjoy it instantly on another device — TMDB metadata rows,
/// poster files, optionally resolved root data maps and watch history.
/// Format spec: docs/BUNDLE-FORMAT.md. The inner `list.txt` is byte-
/// identical to a plain export, so unzipping and importing it always
/// works; every other member is optional and degrades gracefully.

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

final RegExp _rootMapMember = RegExp(r'^rootmaps/([0-9a-f]{64})\.map$');

/// One bundle, parsed and size-checked but not yet applied.
class ParsedBundle {
  const ParsedBundle({
    required this.listText,
    required this.metadataRows,
    required this.posters,
    required this.rootMaps,
    required this.libraryPrefs,
    required this.history,
  });

  /// The inner plain-text list — feed to [parseMediaListFile] as usual.
  final String listText;

  /// metadata.json rows (validated maps), keyed by lookupKey.
  final Map<String, Map<String, dynamic>> metadataRows;

  /// Poster file bytes by (sanitized) file name.
  final Map<String, Uint8List> posters;

  /// Serialized root data maps by normalized XOR address.
  final Map<String, Uint8List> rootMaps;

  /// library.json per-list prefs by lowercased title.
  final Map<String, ({bool enabled, int position})> libraryPrefs;

  /// history.json rows keyed by normalized address.
  final Map<String, WatchState> history;

  bool get hasSeedableExtras =>
      metadataRows.isNotEmpty ||
      posters.isNotEmpty ||
      rootMaps.isNotEmpty ||
      history.isNotEmpty;
}

/// What [seedBundle] actually applied (for the import snackbar).
class BundleSeedSummary {
  int metadataSeeded = 0;
  int postersSeeded = 0;
  int mapsStored = 0;
  int mapsRejected = 0;
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

/// Options from the export dialog's second step.
class BundleExportOptions {
  const BundleExportOptions({
    required this.includeHistory,
    required this.includeRootMaps,
    this.includeLibrary = false,
  });

  /// Default OFF — shared lists shouldn't leak viewing habits; a
  /// migration backup opts in explicitly.
  final bool includeHistory;

  /// Default ON — the addresses are already in list.txt, so bundling the
  /// maps adds instant playback without a privacy delta.
  final bool includeRootMaps;

  /// Library export only: add library.json (per-list order/visibility).
  final bool includeLibrary;
}

class BundleBuildResult {
  const BundleBuildResult({
    required this.bytes,
    required this.rootMapsIncluded,
    required this.rootMapsMissing,
  });

  final Uint8List bytes;
  final int rootMapsIncluded;

  /// Addresses without a locally stored root map (pre-resolve cancelled
  /// or failed) — the bundle still imports fine, those entries just
  /// resolve over the network.
  final int rootMapsMissing;
}

/// Assemble a `.watch-list` bundle for [lists]. Metadata, posters and
/// root maps are whatever is cached locally right now — run the
/// pre-resolve pass first so entries never browsed/played are covered;
/// cancelling that pass simply leaves gaps that degrade gracefully.
Future<BundleBuildResult> buildBundle(
  List<MediaList> lists,
  BundleExportOptions options, {
  String? base,
  Future<Directory> Function()? postersDirProvider,
}) async {
  base ??= EmbeddedClient.baseUrl();
  final archive = Archive();
  final listText = lists.map(serializeMediaList).join();
  archive.addFile(ArchiveFile.string('list.txt', listText));

  final entries = [for (final list in lists) ...list.entries];
  final addresses = <String>{
    for (final e in entries) _normalizeAddr(e.address),
  };

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

  // rootmaps/ — only locally stored maps; never a network resolve here.
  var mapsIncluded = 0, mapsMissing = 0;
  if (options.includeRootMaps && base != null) {
    final client = HttpClient();
    try {
      for (final addr in addresses) {
        try {
          final req = await client.getUrl(Uri.parse('$base/rootmap/$addr'));
          final res = await req.close();
          final builder = BytesBuilder(copy: false);
          await res.forEach(builder.add);
          if (res.statusCode == 200) {
            archive.addFile(ArchiveFile.bytes(
                'rootmaps/$addr.map', builder.takeBytes()));
            mapsIncluded++;
          } else {
            mapsMissing++;
          }
        } catch (_) {
          mapsMissing++;
        }
      }
    } finally {
      client.close(force: true);
    }
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

  if (options.includeHistory) {
    final states = await (db.select(db.watchStates)
          ..where((t) => t.address.isIn(addresses)))
        .get();
    if (states.isNotEmpty) {
      archive.addFile(ArchiveFile.string(
        'history.json',
        jsonEncode({
          'version': 1,
          'entries': [
            for (final s in states)
              {
                'address': s.address,
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
    rootMapsIncluded: mapsIncluded,
    rootMapsMissing: mapsMissing,
  );
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Decode and size-check a bundle. Only `list.txt` is required; malformed
/// or oversized optional members are dropped (import never fails on
/// extras), but a decompressed-size lie big enough to matter throws.
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
  final metadataRows = <String, Map<String, dynamic>>{};
  final posters = <String, Uint8List>{};
  final rootMaps = <String, Uint8List>{};
  final libraryPrefs = <String, ({bool enabled, int position})>{};
  final history = <String, WatchState>{};

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
            final addr = row['address'];
            if (addr is! String || !looksLikeXorAddress(addr)) continue;
            history[_normalizeAddr(addr)] = WatchState(
              address: _normalizeAddr(addr),
              positionMs: row['positionMs'] as int? ?? 0,
              durationMs: row['durationMs'] as int? ?? 0,
              completed: row['completed'] as bool? ?? false,
              updatedAt: row['updatedAt'] as int? ?? 0,
            );
          }
        } catch (_) {}
      default:
        final mapMatch = _rootMapMember.firstMatch(name);
        if (mapMatch != null) {
          final data = readCapped(file, kMaxRootMapBytes);
          if (data != null) rootMaps[mapMatch.group(1)!] = data;
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

  if (listText == null) {
    throw const ListImportException(
        'This bundle has no list.txt inside — nothing to import.');
  }
  return ParsedBundle(
    listText: listText,
    metadataRows: metadataRows,
    posters: posters,
    rootMaps: rootMaps,
    libraryPrefs: libraryPrefs,
    history: history,
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
/// that don't exist locally), history merges newer-updatedAt-wins, and
/// root maps go through the embedded client's verify-then-store PUT
/// (a tampered map is rejected there and simply resolves over the
/// network later).
Future<BundleSeedSummary> seedBundle(
  ParsedBundle bundle, {
  String? base,
  Future<Directory> Function()? postersDirProvider,
}) async {
  final summary = BundleSeedSummary();
  final db = await LibraryStore.database();
  final now = DateTime.now().millisecondsSinceEpoch;

  // Metadata rows: fill gaps only.
  if (bundle.metadataRows.isNotEmpty) {
    final existing = await (db.selectOnly(db.metadataCache)
          ..addColumns([db.metadataCache.lookupKey])
          ..where(db.metadataCache.lookupKey
              .isIn(bundle.metadataRows.keys.toList())))
        .map((row) => row.read(db.metadataCache.lookupKey)!)
        .get();
    final have = existing.toSet();
    for (final entry in bundle.metadataRows.entries) {
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
        summary.metadataSeeded++;
      } catch (_) {
        // A malformed row (wrong types) skips, the rest still seed.
      }
    }
  }

  // Poster files: existing files win.
  if (bundle.posters.isNotEmpty) {
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    await dir.create(recursive: true);
    for (final entry in bundle.posters.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (file.existsSync()) continue;
      try {
        await file.writeAsBytes(entry.value, flush: true);
        summary.postersSeeded++;
      } catch (_) {}
    }
  }

  // Root maps: verified offline (in Rust) before storing.
  base ??= EmbeddedClient.baseUrl();
  if (bundle.rootMaps.isNotEmpty && base != null) {
    final client = HttpClient();
    try {
      for (final entry in bundle.rootMaps.entries) {
        try {
          final req = await client
              .putUrl(Uri.parse('$base/rootmap/${entry.key}'));
          req.add(entry.value);
          final res = await req.close();
          await res.drain<void>();
          if (res.statusCode >= 200 && res.statusCode < 300) {
            summary.mapsStored++;
          } else {
            summary.mapsRejected++;
          }
        } catch (_) {
          summary.mapsRejected++;
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  // Watch history: newer-updatedAt-wins, never regresses local progress.
  if (bundle.history.isNotEmpty) {
    summary.historyMerged =
        await WatchStateStore.instance.mergeAll(bundle.history.values);
  }

  return summary;
}
