import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'app_settings.dart';
import 'library_store.dart';
import 'metadata.dart';
import 'tmdb_client.dart';

/// On-device metadata matcher: file name → TMDB → artwork/description/
/// category, cached in SQLite (metadata_cache table) with poster files on
/// disk — the same pipeline media servers run, but client-side.
///
/// Screens call the synchronous [metadataFor] during build; it returns the
/// best answer known right now (memory → bundled catalog → parsed name)
/// and, when the answer might improve, schedules a background resolve
/// (cache read, then a TMDB fetch if an API key is configured). Listeners
/// are notified when something better lands, so wrap poster/detail widgets
/// in a `ListenableBuilder(listenable: MetadataService.instance)`.
class MetadataService extends ChangeNotifier {
  MetadataService({
    http.Client? httpClient,
    Future<Directory> Function()? postersDirProvider,
    Future<String> Function()? apiKeyProvider,
  })  : _httpClient = httpClient, // ignore: prefer_initializing_formals
        _postersDirProvider = postersDirProvider ?? _defaultPostersDir,
        _apiKeyProvider = apiKeyProvider ?? AppSettings.tmdbApiKey;

  /// Replaceable for tests (fresh instance per test).
  static MetadataService instance = MetadataService();

  /// Confirmed TMDB misses are retried after this long — new releases get
  /// TMDB entries over time, and typos get fixed by renaming (new key).
  static const notFoundTtl = Duration(days: 7);

  final http.Client? _httpClient;
  final Future<Directory> Function() _postersDirProvider;
  final Future<String> Function() _apiKeyProvider;

  /// Best known metadata per lookup key. A key mapping to `null` means
  /// "resolved this session, nothing better than the fallback" (no key
  /// configured, TMDB miss, or transport error) — stops re-scheduling.
  final _memory = <String, MediaMetadata?>{};
  final _inFlight = <String, Future<void>>{};

  static Future<Directory> _defaultPostersDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/posters');
  }

  /// Best metadata known right now for [entry]; may kick off a background
  /// resolve that fires [notifyListeners] later.
  MediaMetadata metadataFor(MediaEntry entry) {
    final fallback = fallbackMetadataFor(entry);
    final key = parseMediaName(entry.name).lookupKey;
    if (_memory.containsKey(key)) return _memory[key] ?? fallback;
    // Async gap so a resolve completing mid-build can't notify listeners
    // during build.
    _inFlight[key] ??= Future(() => _resolve(key, entry.name));
    return fallback;
  }

  /// Completes when no lookups are running — test synchronization only.
  @visibleForTesting
  Future<void> whenIdle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.values.toList());
    }
  }

  /// Forget session state and confirmed misses so the next build re-runs
  /// matching — called when the API key changes.
  Future<void> reset() async {
    _memory.clear();
    _inFlight.clear();
    final db = await LibraryStore.database();
    await (db.delete(db.metadataCache)
          ..where((t) => t.found.equals(false)))
        .go();
    notifyListeners();
  }

  Future<void> _resolve(String key, String fileName) async {
    try {
      final resolved = await _fromCache(key) ?? await _fetch(key, fileName);
      _memory[key] = resolved;
      if (resolved != null) notifyListeners();
    } on _CachedMiss {
      _memory[key] = null;
    } catch (e) {
      // Transport error (offline, rate limit, bad key): leave the cache
      // untouched and stop retrying until the next app start or reset().
      debugPrint('metadata: lookup failed for "$fileName": $e');
      _memory[key] = null;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<MediaMetadata?> _fromCache(String key) async {
    final db = await LibraryStore.database();
    final row = await (db.select(db.metadataCache)
          ..where((t) => t.lookupKey.equals(key)))
        .getSingleOrNull();
    if (row == null) return null;
    if (!row.found) {
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(row.fetchedAt));
      if (age > notFoundTtl && (await _apiKeyProvider()).isNotEmpty) {
        return null; // stale miss: fall through to a fresh TMDB attempt
      }
      throw const _CachedMiss();
    }
    String? posterFilePath;
    if (row.posterFile != null) {
      final f = File('${(await _postersDirProvider()).path}/${row.posterFile}');
      if (f.existsSync()) posterFilePath = f.path;
    }
    return MediaMetadata(
      title: row.title ?? '',
      year: row.year,
      overview: row.overview,
      category: row.category,
      episodeLabel: row.episodeLabel,
      posterFilePath: posterFilePath,
    );
  }

  Future<MediaMetadata?> _fetch(String key, String fileName) async {
    final apiKey = await _apiKeyProvider();
    if (apiKey.isEmpty) return null; // matching disabled; nothing cached
    final client = TmdbClient(apiKey: apiKey, client: _httpClient);
    try {
      final match = await client.lookup(parseMediaName(fileName));
      final db = await LibraryStore.database();
      if (match == null) {
        await db.into(db.metadataCache).insertOnConflictUpdate(
              MetadataCacheCompanion.insert(
                lookupKey: key,
                found: false,
                fetchedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
        return null;
      }
      String? posterFile;
      String? posterFilePath;
      if (match.posterPath != null) {
        try {
          final bytes = await client.fetchPoster(match.posterPath!);
          final dir = await _postersDirProvider();
          await dir.create(recursive: true);
          // Episode matches carry season artwork — one file per season,
          // so a show-level match keeps its own show poster.
          posterFile = match.season == null
              ? '${match.mediaType}_${match.tmdbId}.jpg'
              : '${match.mediaType}_${match.tmdbId}_s${match.season}.jpg';
          final f = File('${dir.path}/$posterFile');
          await f.writeAsBytes(bytes, flush: true);
          posterFilePath = f.path;
        } on TmdbException catch (e) {
          // Artwork is decoration — keep the textual match without it.
          debugPrint('metadata: poster fetch failed for "$fileName": $e');
        }
      }
      await db.into(db.metadataCache).insertOnConflictUpdate(
            MetadataCacheCompanion.insert(
              lookupKey: key,
              found: true,
              title: Value(match.title),
              year: Value(match.year),
              overview: Value(match.overview),
              category: Value(match.category),
              episodeLabel: Value(match.episodeLabel),
              posterFile: Value(posterFile),
              mediaType: Value(match.mediaType),
              tmdbId: Value(match.tmdbId),
              fetchedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      return MediaMetadata(
        title: match.title,
        year: match.year,
        overview: match.overview,
        category: match.category,
        episodeLabel: match.episodeLabel,
        posterFilePath: posterFilePath,
      );
    } finally {
      // Only close clients we created — injected ones belong to the test.
      if (_httpClient == null) client.close();
    }
  }
}

/// Cache row says TMDB has no match (and the row is fresh) — resolve to
/// the fallback without a network attempt.
class _CachedMiss implements Exception {
  const _CachedMiss();
}

/// Poster widget for [meta]: cached TMDB artwork beats the bundled asset;
/// `null` when there is no artwork (caller shows its placeholder).
Widget? posterImage(MediaMetadata meta, {BoxFit? fit}) {
  if (meta.posterFilePath != null) {
    return Image.file(File(meta.posterFilePath!), fit: fit);
  }
  if (meta.posterAsset != null) return Image.asset(meta.posterAsset!, fit: fit);
  return null;
}
