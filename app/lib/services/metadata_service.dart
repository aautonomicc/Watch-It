import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'app_settings.dart';
import 'caa_client.dart';
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

  /// User-authored show/season rows by their episode-less lookup key
  /// (`tv:title:year` / `…:sN` — keys no entry resolves under), overlaid
  /// on every episode's metadata. `null` = resolved, no user row.
  final _overlays = <String, _UserOverlay?>{};

  static Future<Directory> _defaultPostersDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/posters');
  }

  /// Best metadata known right now for [entry]; may kick off a background
  /// resolve that fires [notifyListeners] later.
  MediaMetadata metadataFor(MediaEntry entry) {
    final fallback = fallbackMetadataFor(entry);
    final parsed = parseMediaName(entry.name);
    final key = parsed.lookupKey;
    MediaMetadata meta;
    if (_memory.containsKey(key)) {
      meta = _memory[key] ?? fallback;
    } else {
      // Async gap so a resolve completing mid-build can't notify
      // listeners during build.
      _inFlight[key] ??= Future(() => _resolve(key, entry.name));
      meta = fallback;
    }
    if (parsed.isTrack) {
      // All tracks of one album share the cached row (title/year/cover);
      // the track's own number and name only exist in its file name, so
      // re-attach them to whatever the shared row resolved to. A
      // user-authored track row (Edit details on the track) overrides
      // the file-name label and carries the track's OWN artwork and
      // artist credit — per-entry slots, so album covers and cards
      // (which read the first track) never show one track's edits.
      final track = _overlayFor(trackLookupKey(parsed)!);
      return MediaMetadata(
        title: meta.title,
        year: meta.year,
        overview: meta.overview,
        category: meta.category,
        episodeLabel: track?.episodeLabel ?? trackLabel(parsed),
        posterAsset: meta.posterAsset,
        posterFilePath: meta.posterFilePath,
        episodePosterFilePath: track?.posterFilePath,
        rating: meta.rating,
        mediaType: meta.mediaType ?? 'music',
        artist: meta.artist ?? parsed.artist,
        trackArtist: track?.artist ?? parsed.artist,
      );
    }
    if (!parsed.isEpisode) return meta;
    // Show/season pages and cards read metadataFor(first episode), so
    // user-authored show/season details must reach them through every
    // episode: overlay the show row (title/year/synopsis/show poster)
    // and season row (season artwork/synopsis) when the user wrote one.
    final show = _overlayFor(parsed.showLookupKey);
    final season = _overlayFor(parsed.seasonLookupKey!);
    if (show == null && season == null) return meta;
    return MediaMetadata(
      title: show?.title ?? meta.title,
      year: show?.year ?? meta.year,
      overview: meta.overview,
      category: meta.category,
      episodeLabel: meta.episodeLabel,
      posterAsset: meta.posterAsset,
      posterFilePath: season?.posterFilePath ?? meta.posterFilePath,
      rating: meta.rating,
      showOverview: show?.overview ?? meta.showOverview,
      seasonOverview: season?.overview ?? meta.seasonOverview,
      airDate: meta.airDate,
      stillFilePath: meta.stillFilePath,
      showPosterFilePath: show?.posterFilePath ?? meta.showPosterFilePath,
      episodePosterFilePath: meta.episodePosterFilePath,
      mediaType: meta.mediaType,
    );
  }

  /// The user's show/season overlay under [key], if resolved; kicks off
  /// a cache read (never a TMDB fetch — these keys are user-only) the
  /// first time and returns null until it lands.
  _UserOverlay? _overlayFor(String key) {
    if (_overlays.containsKey(key)) return _overlays[key];
    _inFlight['overlay:$key'] ??= Future(() => _resolveOverlay(key));
    return null;
  }

  Future<void> _resolveOverlay(String key) async {
    try {
      final db = await LibraryStore.database();
      final row = await (db.select(db.metadataCache)
            ..where((t) => t.lookupKey.equals(key)))
          .getSingleOrNull();
      if (row == null || !row.found || !row.userEdited) {
        _overlays[key] = null;
        return;
      }
      final postersDir = (await _postersDirProvider()).path;
      String? posterPath;
      if (row.posterFile != null) {
        final f = File('$postersDir/${row.posterFile}');
        if (f.existsSync()) posterPath = f.path;
      }
      _overlays[key] = _UserOverlay(
        title: row.title,
        year: row.year,
        overview: row.overview,
        episodeLabel: row.episodeLabel,
        posterFilePath: posterPath,
        artist: row.artist,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('metadata: overlay lookup failed for "$key": $e');
      _overlays[key] = null;
    } finally {
      _inFlight.remove('overlay:$key');
    }
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
    _overlays.clear();
    _inFlight.clear();
    final db = await LibraryStore.database();
    await (db.delete(db.metadataCache)
          ..where((t) => t.found.equals(false)))
        .go();
    notifyListeners();
  }

  /// Forget this session's in-memory answers so rows seeded from outside
  /// (a bundle import) are picked up on the next build. Unlike [reset]
  /// this leaves the SQLite cache alone — the seeded rows are the point.
  void notifyExternalSeed() {
    _memory.clear();
    _overlays.clear();
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
    final postersDir = (await _postersDirProvider()).path;
    String? existingFile(String? name) {
      if (name == null) return null;
      final f = File('$postersDir/$name');
      return f.existsSync() ? f.path : null;
    }

    // For episode rows posterFile is the SEASON artwork slot (season
    // tiles/headers read it through their first episode), but an
    // episode-scope artwork edit stores the user's file there: serve
    // that file as episode-only art instead, and put the TMDB season
    // poster — one shared file per season, its name derivable from the
    // row's TMDB id — back in the season slot.
    var posterPath = existingFile(row.posterFile);
    String? episodePosterPath;
    final ep = RegExp(r':s(\d+):e\d+$').firstMatch(key);
    if (ep != null && row.userEdited) {
      if (row.posterFile?.startsWith('user_') ?? false) {
        episodePosterPath = posterPath;
        posterPath = null;
      }
      posterPath ??= row.tmdbId == null
          ? null
          : existingFile(
              '${row.mediaType}_${row.tmdbId}_s${ep.group(1)}.jpg');
    }

    return MediaMetadata(
      title: row.title ?? '',
      year: row.year,
      overview: row.overview,
      category: row.category,
      episodeLabel: row.episodeLabel,
      posterFilePath: posterPath,
      episodePosterFilePath: episodePosterPath,
      rating: row.rating,
      showOverview: row.showOverview,
      seasonOverview: row.seasonOverview,
      airDate: row.airDate,
      stillFilePath: existingFile(row.stillFile),
      showPosterFilePath: existingFile(row.showPosterFile),
      mediaType: row.mediaType,
      artist: row.artist,
    );
  }

  Future<MediaMetadata?> _fetch(String key, String fileName) async {
    final parsed = parseMediaName(fileName);
    // Audio never goes to TMDB: album metadata is in the file name and
    // cover art comes keyless from the Cover Art Archive.
    if (parsed.isAudio) return _fetchMusic(key, parsed);
    final apiKey = await _apiKeyProvider();
    if (apiKey.isEmpty) return null; // matching disabled; nothing cached
    final client = TmdbClient(apiKey: apiKey, client: _httpClient);
    try {
      final match = await client.lookup(parseMediaName(fileName));
      if (match == null) {
        final db = await LibraryStore.database();
        await db.into(db.metadataCache).insertOnConflictUpdate(
              MetadataCacheCompanion.insert(
                lookupKey: key,
                found: false,
                fetchedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
        return null;
      }
      return await _persistMatch(key, match, client);
    } finally {
      // Only close clients we created — injected ones belong to the test.
      if (_httpClient == null) client.close();
    }
  }

  /// Music resolve: the file name already carries everything displayable
  /// (artist/album/year/track — the CLI writes canonical MusicBrainz
  /// data into it), so the only fetch is the album's front cover from
  /// the Cover Art Archive, keyed by the `{mbid-...}` release id. No
  /// mbid → nothing to fetch, the parsed fallback is already complete.
  /// A transport error propagates (caught in [_resolve]) so nothing is
  /// cached and the art is retried next session; a CAA 404 means the
  /// release has no cover — cached as a found row without artwork.
  Future<MediaMetadata?> _fetchMusic(String key, ParsedName parsed) async {
    final mbid = parsed.releaseMbid;
    if (mbid == null) return null;
    String? posterFile;
    String? posterPath;
    final dir = await _postersDirProvider();
    final f = File('${dir.path}/music_$mbid.jpg');
    if (f.existsSync()) {
      posterFile = 'music_$mbid.jpg';
      posterPath = f.path;
    } else {
      final client = CaaClient(client: _httpClient);
      try {
        final bytes = await client.fetchFront(mbid);
        if (bytes != null) {
          dir.createSync(recursive: true);
          // Sync IO on purpose — same fake-async rule as _persistMatch.
          f.writeAsBytesSync(bytes, flush: true);
          posterFile = 'music_$mbid.jpg';
          posterPath = f.path;
        }
      } finally {
        if (_httpClient == null) client.close();
      }
    }
    final db = await LibraryStore.database();
    await db.into(db.metadataCache).insertOnConflictUpdate(
          MetadataCacheCompanion.insert(
            lookupKey: key,
            found: true,
            title: Value(parsed.title),
            year: Value(parsed.year),
            posterFile: Value(posterFile),
            mediaType: const Value('music'),
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
            userEdited: const Value(false),
            artist: Value(parsed.artist),
          ),
        );
    return MediaMetadata(
      title: parsed.title,
      year: parsed.year,
      posterFilePath: posterPath,
      mediaType: 'music',
      artist: parsed.artist,
    );
  }

  /// Whether TMDB lookups can run at all (a key is configured).
  Future<bool> get hasTmdbKey async => (await _apiKeyProvider()).isNotEmpty;

  /// Explicit TMDB lookup for [parsed] — the Describe-this-item "Check
  /// TMDB" button, searching with whatever title/year the publisher
  /// typed. Nothing is cached or written; the caller previews the match
  /// and commits it via [adoptTmdbMatch]. Returns `null` on a genuine
  /// miss; throws [TmdbException] on transport/API errors.
  Future<TmdbMatch?> lookupTmdb(ParsedName parsed) async {
    final client =
        TmdbClient(apiKey: await _apiKeyProvider(), client: _httpClient);
    try {
      return await client.lookup(parsed);
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// Poster bytes for a [lookupTmdb] preview; `null` when the match has
  /// no poster or the CDN fetch fails (artwork is decoration).
  Future<Uint8List?> tmdbPosterBytes(TmdbMatch match) async {
    if (match.posterPath == null) return null;
    final client =
        TmdbClient(apiKey: await _apiKeyProvider(), client: _httpClient);
    try {
      return Uint8List.fromList(await client.fetchPoster(match.posterPath!));
    } on TmdbException {
      return null;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// Commit a previewed [match] for [key] through the normal fetch
  /// pipeline: full cache row (rating/genres/TMDB id included — they
  /// travel in channel manifests and bundle exports) plus artwork files
  /// under the shared TMDB naming. Replaces whatever row the key held —
  /// the user explicitly chose this match.
  Future<MediaMetadata> adoptTmdbMatch(String key, TmdbMatch match) async {
    final client =
        TmdbClient(apiKey: await _apiKeyProvider(), client: _httpClient);
    try {
      final resolved = await _persistMatch(key, match, client);
      _memory[key] = resolved;
      notifyListeners();
      return resolved;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// Write [match] into the cache row for [key] and its images into the
  /// posters dir. File IO is synchronous on purpose — this runs from
  /// widget flows exercised under fake-async tests, where pending real
  /// async IO never completes (same rule as services/user_metadata.dart).
  Future<MediaMetadata> _persistMatch(
      String key, TmdbMatch match, TmdbClient client) async {
    final db = await LibraryStore.database();
    final dir = await _postersDirProvider();
    // Download one CDN image into the posters dir, skipping files that
    // are already on disk (episodes of one season share the season
    // poster and the show poster). Artwork is decoration — a failed
    // fetch keeps the textual match without it.
    Future<(String, String)?> saveImage(String? cdnPath, String file,
        Future<List<int>> Function(String) fetch) async {
      if (cdnPath == null) return null;
      try {
        final f = File('${dir.path}/$file');
        if (!f.existsSync()) {
          final bytes = await fetch(cdnPath);
          dir.createSync(recursive: true);
          f.writeAsBytesSync(bytes, flush: true);
        }
        return (file, f.path);
      } on TmdbException catch (e) {
        debugPrint('metadata: image fetch failed for "$key": $e');
        return null;
      }
    }

    // Episode matches carry season artwork — one file per season, so a
    // show-level match keeps its own show poster.
    final id = '${match.mediaType}_${match.tmdbId}';
    final poster = await saveImage(
        match.posterPath,
        match.season == null ? '$id.jpg' : '${id}_s${match.season}.jpg',
        client.fetchPoster);
    final showPoster = match.season == null
        ? null
        : await saveImage(match.showPosterPath, '$id.jpg',
            client.fetchPoster);
    final still = match.season == null
        ? null
        : await saveImage(
            match.stillPath,
            '${id}_s${match.season}e${match.episode}_still.jpg',
            client.fetchStill);
    await db.into(db.metadataCache).insertOnConflictUpdate(
          MetadataCacheCompanion.insert(
            lookupKey: key,
            found: true,
            title: Value(match.title),
            year: Value(match.year),
            overview: Value(match.overview),
            category: Value(match.category),
            episodeLabel: Value(match.episodeLabel),
            posterFile: Value(poster?.$1),
            mediaType: Value(match.mediaType),
            tmdbId: Value(match.tmdbId),
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
            rating: Value(match.rating),
            showOverview: Value(match.showOverview),
            seasonOverview: Value(match.seasonOverview),
            airDate: Value(match.airDate),
            stillFile: Value(still?.$1),
            showPosterFile: Value(showPoster?.$1),
            userEdited: const Value(false),
          ),
        );
    return MediaMetadata(
      title: match.title,
      year: match.year,
      overview: match.overview,
      category: match.category,
      episodeLabel: match.episodeLabel,
      posterFilePath: poster?.$2,
      rating: match.rating,
      showOverview: match.showOverview,
      seasonOverview: match.seasonOverview,
      airDate: match.airDate,
      stillFilePath: still?.$2,
      showPosterFilePath: showPoster?.$2,
      mediaType: match.mediaType,
    );
  }
}

/// Cache row says TMDB has no match (and the row is fresh) — resolve to
/// the fallback without a network attempt.
class _CachedMiss implements Exception {
  const _CachedMiss();
}

/// A user-authored show/season/track cache row, reduced to the fields
/// that overlay entry metadata. Fields left null fall back to the
/// shared row's values.
class _UserOverlay {
  const _UserOverlay(
      {this.title,
      this.year,
      this.overview,
      this.episodeLabel,
      this.posterFilePath,
      this.artist});

  final String? title;
  final int? year;
  final String? overview;
  final String? episodeLabel;
  final String? posterFilePath;
  final String? artist;
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

/// The user's own artwork for an episode or music-track entry (Edit
/// details on that entry), never season/show/album art; `null` for
/// everything else.
Widget? episodePosterImage(MediaMetadata meta, {BoxFit? fit}) {
  if (meta.episodePosterFilePath == null) return null;
  return Image.file(File(meta.episodePosterFilePath!), fit: fit);
}

/// Poster for an entry's own surfaces (its detail page, per-entry
/// cards, the playing track's cover): an episode's or track's user
/// artwork beats the season/album-art slot. Same as [posterImage] for
/// everything else.
Widget? entryPosterImage(MediaMetadata meta, {BoxFit? fit}) =>
    episodePosterImage(meta, fit: fit) ?? posterImage(meta, fit: fit);

/// Show-level poster for an episode's [meta] (its [posterImage] is the
/// season artwork); falls back to the season/regular artwork.
Widget? showPosterImage(MediaMetadata meta, {BoxFit? fit}) {
  if (meta.showPosterFilePath != null) {
    return Image.file(File(meta.showPosterFilePath!), fit: fit);
  }
  return posterImage(meta, fit: fit);
}

/// Cached episode screenshot, or `null` when TMDB has none.
Widget? stillImage(MediaMetadata meta, {BoxFit? fit}) {
  if (meta.stillFilePath == null) return null;
  return Image.file(File(meta.stillFilePath!), fit: fit);
}
