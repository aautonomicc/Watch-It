import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import 'library_store.dart';
import 'metadata_service.dart';

/// User-authored metadata (Edit details): title/year/description and
/// artwork written straight into the metadata cache under the entry's
/// lookup key, flagged `userEdited`. A found cache row already
/// short-circuits the TMDB fetch, so a user row is never overwritten by
/// a later match; bundle exports carry it like any other row, so
/// recipients of a `.watch-list` see the same details offline.

/// Where poster files live — shared with the My W@tch artwork sync,
/// which hashes and re-saves `user_` files from linked devices.
Future<Directory> defaultPostersDir() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/posters');
}

Future<Directory> _defaultPostersDir() => defaultPostersDir();

/// Poster-file prefix for [lookupKey]: `user_` + the key with every
/// filesystem-hostile character flattened (capped so the name stays
/// sane for long titles) + a stable hash so truncated keys can't share
/// a prefix — the prefix scopes deletion of a key's old artwork.
String userPosterPrefix(String lookupKey) {
  var safe = lookupKey.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
  if (safe.length > 60) safe = safe.substring(0, 60);
  var h = 0x811c9dc5; // FNV-1a, stable across runs and platforms
  for (final c in lookupKey.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return 'user_${safe}_${h.toRadixString(16)}';
}

/// The raw cache row for [lookupKey], if any — the editor reads it to
/// know whether the current details are a TMDB match or the user's own.
Future<MetadataCacheRow?> metadataRowFor(String lookupKey) async {
  final db = await LibraryStore.database();
  return (db.select(db.metadataCache)
        ..where((t) => t.lookupKey.equals(lookupKey)))
      .getSingleOrNull();
}

/// Write [bytes] as the user's artwork for [lookupKey] and return the
/// stored file name. Each save gets a fresh name (Flutter's image cache
/// keys by path, so re-using one would show the stale image) and the
/// previous `user_` files for the key are deleted.
/// File IO is synchronous throughout this service on purpose: it runs
/// from widget flows exercised under fake-async tests, where pending
/// real async IO never completes (same rule as the Publish screen).
Future<String> saveUserPoster(
  String lookupKey,
  Uint8List bytes, {
  Future<Directory> Function()? postersDirProvider,
}) async {
  final dir = await (postersDirProvider ?? _defaultPostersDir)();
  dir.createSync(recursive: true);
  final prefix = userPosterPrefix(lookupKey);
  final name = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
  File('${dir.path}/$name').writeAsBytesSync(bytes, flush: true);
  _deleteUserPosters(dir, prefix, keep: name);
  return name;
}

void _deleteUserPosters(Directory dir, String prefix, {String? keep}) {
  if (!dir.existsSync()) return;
  for (final f in dir.listSync()) {
    if (f is! File) continue;
    final base = f.uri.pathSegments.last;
    if (base != keep && base.startsWith('${prefix}_')) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

/// Upsert the user's details for [lookupKey]. Fields the editor doesn't
/// touch (rating, stills, TMDB id…) are preserved from the existing row
/// so an edit on top of a TMDB match keeps its extras.
/// [posterFile] absent = keep the current artwork; `Value(null)` =
/// remove it (the file itself is only deleted when it is a `user_` one —
/// TMDB artwork files can be shared between rows). [episodeLabel] absent
/// = keep the current label; the episode editor writes `SxxEyy · Name`.
/// [category] absent = keep the current genres; the Describe page writes
/// a `'Horror · Thriller'`-style value (or null to clear).
/// [artist] absent = keep the current album artist; the music editor
/// writes it (music rows only).
Future<void> saveUserDetails({
  required String lookupKey,
  required String title,
  int? year,
  String? overview,
  Value<String?> episodeLabel = const Value.absent(),
  Value<String?> posterFile = const Value.absent(),
  Value<String?> category = const Value.absent(),
  Value<String?> artist = const Value.absent(),
  Future<Directory> Function()? postersDirProvider,
}) async {
  final db = await LibraryStore.database();
  final existing = await metadataRowFor(lookupKey);
  final newPoster =
      posterFile.present ? posterFile.value : existing?.posterFile;
  if (posterFile.present &&
      existing?.posterFile != null &&
      existing!.posterFile != newPoster &&
      existing.posterFile!.startsWith('user_')) {
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    try {
      File('${dir.path}/${existing.posterFile}').deleteSync();
    } catch (_) {}
  }
  await db.into(db.metadataCache).insertOnConflictUpdate(
        MetadataCacheCompanion.insert(
          lookupKey: lookupKey,
          found: true,
          title: Value(title),
          year: Value(year),
          overview: Value(
              (overview == null || overview.trim().isEmpty) ? null : overview),
          category: category.present ? category : Value(existing?.category),
          episodeLabel: episodeLabel.present
              ? episodeLabel
              : Value(existing?.episodeLabel),
          posterFile: Value(newPoster),
          mediaType: Value(existing?.mediaType),
          tmdbId: Value(existing?.tmdbId),
          artist: artist.present ? artist : Value(existing?.artist),
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
          rating: Value(existing?.rating),
          showOverview: Value(existing?.showOverview),
          seasonOverview: Value(existing?.seasonOverview),
          airDate: Value(existing?.airDate),
          stillFile: Value(existing?.stillFile),
          showPosterFile: Value(existing?.showPosterFile),
          userEdited: const Value(true),
        ),
      );
  MetadataService.instance.notifyExternalSeed();
}

/// Apply a linked device's user-edit row (My W@tch sync). Same upsert
/// as [saveUserDetails] except the row is stamped with the *remote*
/// edit time [updatedMs] instead of now — both devices then hold the
/// identical stamp and the last-writer-wins comparison converges
/// instead of ping-ponging. When the remote row carries no artwork
/// manifest ([remoteHasArt] false) a local `user_` poster is the loser
/// of that LWW round and is removed; TMDB artwork is never touched
/// (a remote text-only edit keeps whatever TMDB art each device has).
Future<void> applyRemoteUserDetails({
  required String lookupKey,
  required String title,
  int? year,
  String? overview,
  String? episodeLabel,
  required int updatedMs,
  required bool remoteHasArt,
  Future<Directory> Function()? postersDirProvider,
}) async {
  final db = await LibraryStore.database();
  final existing = await metadataRowFor(lookupKey);
  var poster = existing?.posterFile;
  if (!remoteHasArt && poster != null && poster.startsWith('user_')) {
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    try {
      File('${dir.path}/$poster').deleteSync();
    } catch (_) {}
    poster = null;
  }
  await db.into(db.metadataCache).insertOnConflictUpdate(
        MetadataCacheCompanion.insert(
          lookupKey: lookupKey,
          found: true,
          title: Value(title),
          year: Value(year),
          overview: Value(
              (overview == null || overview.trim().isEmpty) ? null : overview),
          category: Value(existing?.category),
          episodeLabel: Value(episodeLabel ?? existing?.episodeLabel),
          posterFile: Value(poster),
          mediaType: Value(existing?.mediaType),
          tmdbId: Value(existing?.tmdbId),
          artist: Value(existing?.artist),
          fetchedAt: updatedMs,
          rating: Value(existing?.rating),
          showOverview: Value(existing?.showOverview),
          seasonOverview: Value(existing?.seasonOverview),
          airDate: Value(existing?.airDate),
          stillFile: Value(existing?.stillFile),
          showPosterFile: Value(existing?.showPosterFile),
          userEdited: const Value(true),
        ),
      );
  MetadataService.instance.notifyExternalSeed();
}

/// Apply a linked device's TMDB metadata row (My W@tch sync) — the
/// full-fat match a keyless device cannot fetch itself. The sync loop
/// only calls this when the local cache has nothing better (no row, or
/// a cached miss); the row is stamped with the remote's fetch time and
/// NOT marked userEdited, so a later local edit — or a real TMDB
/// re-match once a key is configured — still wins. The artwork file
/// names are stored as-is; the bytes arrive separately over the art
/// transfer and land in the posters dir under those exact names.
Future<void> applyRemoteTmdbDetails({
  required String lookupKey,
  required int updatedMs,
  String? title,
  int? year,
  String? overview,
  String? category,
  String? episodeLabel,
  String? mediaType,
  int? tmdbId,
  double? rating,
  String? airDate,
  String? showOverview,
  String? seasonOverview,
  String? posterFile,
  String? stillFile,
  String? showPosterFile,
}) async {
  final db = await LibraryStore.database();
  await db.into(db.metadataCache).insertOnConflictUpdate(
        MetadataCacheCompanion.insert(
          lookupKey: lookupKey,
          found: true,
          title: Value(title),
          year: Value(year),
          overview: Value(overview),
          category: Value(category),
          episodeLabel: Value(episodeLabel),
          posterFile: Value(posterFile),
          mediaType: Value(mediaType),
          tmdbId: Value(tmdbId),
          fetchedAt: updatedMs,
          rating: Value(rating),
          showOverview: Value(showOverview),
          seasonOverview: Value(seasonOverview),
          airDate: Value(airDate),
          stillFile: Value(stillFile),
          showPosterFile: Value(showPosterFile),
        ),
      );
  MetadataService.instance.notifyExternalSeed();
}

/// Store synced artwork [bytes] as the user poster for [lookupKey]
/// (fresh `user_` file, older ones deleted) without touching the row's
/// LWW stamp — the text row was already applied with the remote's
/// timestamp and the artwork completing later must not look like a
/// newer local edit.
Future<void> applyRemotePoster(
  String lookupKey,
  Uint8List bytes, {
  Future<Directory> Function()? postersDirProvider,
}) async {
  final db = await LibraryStore.database();
  final existing = await metadataRowFor(lookupKey);
  if (existing == null) return;
  final name = await saveUserPoster(lookupKey, bytes,
      postersDirProvider: postersDirProvider);
  await (db.update(db.metadataCache)
        ..where((t) => t.lookupKey.equals(lookupKey)))
      .write(MetadataCacheCompanion(posterFile: Value(name)));
  MetadataService.instance.notifyExternalSeed();
}

/// Drop the user's edits for [lookupKey]: the row is deleted (so the
/// next build re-matches from TMDB when a key is configured) and the
/// key's `user_` artwork files go with it.
Future<void> clearUserEdits(
  String lookupKey, {
  Future<Directory> Function()? postersDirProvider,
}) async {
  final db = await LibraryStore.database();
  await (db.delete(db.metadataCache)
        ..where((t) => t.lookupKey.equals(lookupKey) &
            t.userEdited.equals(true)))
      .go();
  final dir = await (postersDirProvider ?? _defaultPostersDir)();
  _deleteUserPosters(dir, userPosterPrefix(lookupKey));
  MetadataService.instance.notifyExternalSeed();
}
