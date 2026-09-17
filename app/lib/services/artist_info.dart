import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import 'library_store.dart';
import 'musicbrainz_client.dart';
import 'network_pause.dart';
import 'wikimedia_client.dart';

/// Shown in Settings → About beside the TMDB attribution — the artist
/// pages' data sources are keyless but still deserve credit (and the
/// Wikipedia text legally requires it).
const kArtistInfoAttributionNotice =
    'Artist pages use data from MusicBrainz and Wikidata, with '
    'biographies and portraits from Wikipedia and Wikimedia Commons. '
    'Biography text is licensed CC BY-SA.';

/// Everything the artist page shows beyond the album tiles.
class ArtistInfo {
  const ArtistInfo({
    required this.name,
    this.mbid,
    this.bio,
    this.bioUrl,
    this.formedYear,
    this.country,
    this.genres,
    this.portraitPath,
  });

  /// Canonical MusicBrainz artist name.
  final String name;
  final String? mbid;

  /// Wikipedia article extract; [bioUrl] links the source article
  /// (CC BY-SA attribution).
  final String? bio;
  final String? bioUrl;
  final int? formedYear;
  final String? country;

  /// Top genres joined ` · ` (the category convention).
  final String? genres;

  /// Absolute path of the cached portrait file, existence-checked.
  final String? portraitPath;

  /// The `Formed 1965 · London · Rock` facts line; null when no fact is
  /// known (the page then keeps just its album/track counts).
  String? get factsLine {
    final parts = [
      if (formedYear != null) 'Formed $formedYear',
      ?country,
      ?genres,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// Keyless artist-info matcher for the artist page: release `{mbid-...}`
/// tags (or an exact-name search) → MusicBrainz artist → facts +
/// Wikidata id → Wikipedia bio + Commons portrait, cached in SQLite
/// (artist_meta table) with the portrait on disk. PULL-ONCE: the chain
/// runs the first time an artist page opens with no cached row and never
/// again — misses included — until the page's explicit Refresh action.
/// Offline-first: a cached row renders with zero network. Same shape as
/// [MetadataService]: screens call the sync [infoFor] during build
/// inside a `ListenableBuilder(listenable: ArtistInfoService.instance)`.
class ArtistInfoService extends ChangeNotifier {
  ArtistInfoService({
    http.Client? httpClient,
    Future<Directory> Function()? postersDirProvider,
    bool Function()? pausedProvider,
    Duration? mbInterval,
  })  : _httpClient = httpClient, // ignore: prefer_initializing_formals
        _postersDirProvider = postersDirProvider ?? _defaultPostersDir,
        _pausedProvider =
            pausedProvider ?? (() => NetworkPause.instance.paused),
        _mbInterval = mbInterval; // ignore: prefer_initializing_formals

  /// Replaceable for tests (fresh instance per test).
  static ArtistInfoService instance = ArtistInfoService();

  final http.Client? _httpClient;
  final Future<Directory> Function() _postersDirProvider;
  final bool Function() _pausedProvider;
  final Duration? _mbInterval;

  /// Resolved info per artist key. A key mapping to `null` means
  /// "resolved this session, nothing to show" (cached miss, Offline
  /// mode, or transport error) — stops re-scheduling.
  final _memory = <String, ArtistInfo?>{};
  final _inFlight = <String, Future<void>>{};
  final _refreshing = <String>{};

  static Future<Directory> _defaultPostersDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/posters');
  }

  /// The cache key for [artist] — the same normalization the wall's
  /// artist fold uses, so one row serves however the name is cased.
  static String keyFor(String artist) => artist.trim().toLowerCase();

  /// Info known right now for [artist]; may kick off a one-time
  /// background resolve that fires [notifyListeners] later.
  /// [releaseMbids] are the `{mbid-...}` tags on the artist's tracks —
  /// the reliable identity signal; [displayName] is the (possibly
  /// user-corrected) name shown on the page, used for the search
  /// fallback.
  ArtistInfo? infoFor(String artist,
      {String? displayName, List<String> releaseMbids = const []}) {
    final key = keyFor(artist);
    if (_memory.containsKey(key)) return _memory[key];
    // Async gap so a resolve completing mid-build can't notify
    // listeners during build.
    _inFlight[key] ??=
        Future(() => _resolve(key, displayName ?? artist, releaseMbids));
    return null;
  }

  /// True while [refresh] runs for [artist] — drives the page's app-bar
  /// spinner.
  bool refreshing(String artist) => _refreshing.contains(keyFor(artist));

  /// Drop the cached row (and portrait file) and run the chain again —
  /// the ONLY way cached info is ever refetched. Throws on transport
  /// errors so the page can tell the user the refresh failed.
  Future<void> refresh(String artist,
      {String? displayName, List<String> releaseMbids = const []}) async {
    final key = keyFor(artist);
    if (_refreshing.contains(key)) return;
    _refreshing.add(key);
    notifyListeners();
    try {
      final db = await LibraryStore.database();
      final row = await (db.select(db.artistMeta)
            ..where((t) => t.artistKey.equals(key)))
          .getSingleOrNull();
      if (row?.portraitFile != null) {
        final dir = await _postersDirProvider();
        final f = File('${dir.path}/${row!.portraitFile}');
        if (f.existsSync()) f.deleteSync();
      }
      await (db.delete(db.artistMeta)..where((t) => t.artistKey.equals(key)))
          .go();
      _memory[key] =
          await _fetch(key, displayName ?? artist, releaseMbids);
    } finally {
      _refreshing.remove(key);
      notifyListeners();
    }
  }

  /// Completes when no lookups are running — test synchronization only.
  @visibleForTesting
  Future<void> whenIdle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.values.toList());
    }
  }

  Future<void> _resolve(String key, String name, List<String> mbids) async {
    try {
      final row = await _rowFor(key);
      if (row != null) {
        // Offline-first: a cached row (hit or miss) is the answer —
        // pull-once means no automatic refetch, ever.
        final info = row.found ? await _infoFromRow(row) : null;
        _memory[key] = info;
        if (info != null) notifyListeners();
        return;
      }
      if (_pausedProvider()) {
        // Offline mode: skip the fetch without caching anything, so
        // the chain runs once the network is back (next session or
        // page revisit after unpausing... next session in practice).
        _memory[key] = null;
        return;
      }
      final info = await _fetch(key, name, mbids);
      _memory[key] = info;
      if (info != null) notifyListeners();
    } catch (e) {
      // Transport error (offline, MB rate limit): cache nothing so the
      // chain retries next session.
      debugPrint('artist info: lookup failed for "$name": $e');
      _memory[key] = null;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<ArtistMetaRow?> _rowFor(String key) async {
    final db = await LibraryStore.database();
    return (db.select(db.artistMeta)..where((t) => t.artistKey.equals(key)))
        .getSingleOrNull();
  }

  Future<ArtistInfo> _infoFromRow(ArtistMetaRow row) async {
    String? portraitPath;
    if (row.portraitFile != null) {
      final dir = await _postersDirProvider();
      final f = File('${dir.path}/${row.portraitFile}');
      if (f.existsSync()) portraitPath = f.path;
    }
    return ArtistInfo(
      name: row.name ?? '',
      mbid: row.mbid,
      bio: row.bio,
      bioUrl: row.bioUrl,
      formedYear: row.formedYear,
      country: row.country,
      genres: row.genres,
      portraitPath: portraitPath,
    );
  }

  /// Run the whole chain and persist the outcome (hit or miss). Only a
  /// MusicBrainz transport error propagates — the Wikimedia legs are
  /// decoration on top of the MB facts, so their failures degrade to a
  /// row without bio/portrait rather than losing everything.
  Future<ArtistInfo?> _fetch(
      String key, String name, List<String> mbids) async {
    final mb = MusicBrainzClient(
      client: _httpClient,
      minInterval: _mbInterval ?? const Duration(milliseconds: 1100),
    );
    final wiki = WikimediaClient(client: _httpClient);
    try {
      final ref = await _resolveArtistRef(mb, key, name, mbids);
      final details =
          ref == null ? null : await mb.artistDetails(ref.id);
      if (ref == null || details == null) {
        await _saveMiss(key);
        return null;
      }

      String? bio;
      String? bioUrl;
      String? imageFile;
      String? thumbnailUrl;
      if (details.wikidataId != null) {
        try {
          final entity = await wiki.entity(details.wikidataId!);
          imageFile = entity?.imageFile;
          if (entity?.enwikiTitle != null) {
            final summary = await wiki.summary(entity!.enwikiTitle!);
            bio = summary?.extract;
            bioUrl = summary?.pageUrl;
            thumbnailUrl = summary?.thumbnailUrl;
          }
        } catch (e) {
          debugPrint('artist info: wiki chain failed for "$name": $e');
        }
      }

      String? portraitFile;
      String? portraitPath;
      try {
        List<int>? bytes;
        if (imageFile != null) {
          bytes = await wiki.commonsFile(imageFile, width: 500);
        }
        if (bytes == null && thumbnailUrl != null) {
          bytes = await wiki.imageBytes(thumbnailUrl);
        }
        if (bytes != null && bytes.isNotEmpty) {
          final dir = await _postersDirProvider();
          dir.createSync(recursive: true);
          final f = File('${dir.path}/artist_${ref.id}.jpg');
          // Sync IO on purpose — same fake-async rule as
          // metadata_service.dart's _persistMatch.
          f.writeAsBytesSync(bytes, flush: true);
          portraitFile = 'artist_${ref.id}.jpg';
          portraitPath = f.path;
        }
      } catch (e) {
        debugPrint('artist info: portrait fetch failed for "$name": $e');
      }

      final db = await LibraryStore.database();
      await db.into(db.artistMeta).insertOnConflictUpdate(
            ArtistMetaCompanion.insert(
              artistKey: key,
              found: true,
              mbid: Value(ref.id),
              name: Value(details.name),
              bio: Value(bio),
              bioUrl: Value(bioUrl),
              formedYear: Value(details.formedYear),
              country: Value(details.area),
              genres: Value(details.genres),
              portraitFile: Value(portraitFile),
              fetchedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      return ArtistInfo(
        name: details.name,
        mbid: ref.id,
        bio: bio,
        bioUrl: bioUrl,
        formedYear: details.formedYear,
        country: details.area,
        genres: details.genres,
        portraitPath: portraitPath,
      );
    } finally {
      if (_httpClient == null) {
        mb.close();
        wiki.close();
      }
    }
  }

  /// Find the MusicBrainz artist: a release the artist's own tracks are
  /// tagged with beats everything (the tag names the exact release —
  /// name-only search can hit a different artist with the same name);
  /// a credit whose name matches the page is accepted outright, and
  /// when every tagged release agrees on ONE artist a formatting-only
  /// name difference is accepted too. Otherwise the exact-name search
  /// decides, or nothing does (a miss beats the wrong artist's bio).
  Future<MbArtistRef?> _resolveArtistRef(MusicBrainzClient mb, String key,
      String name, List<String> mbids) async {
    final seen = <String, MbArtistRef>{};
    for (final releaseMbid in mbids.toSet().take(3)) {
      final ref = await mb.releaseArtist(releaseMbid);
      if (ref == null) continue;
      final refKey = keyFor(ref.name);
      if (refKey == key || refKey == keyFor(name)) return ref;
      seen[ref.id] = ref;
    }
    if (seen.length == 1) return seen.values.single;
    return mb.searchArtist(name);
  }

  Future<void> _saveMiss(String key) async {
    final db = await LibraryStore.database();
    await db.into(db.artistMeta).insertOnConflictUpdate(
          ArtistMetaCompanion.insert(
            artistKey: key,
            found: false,
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }
}
