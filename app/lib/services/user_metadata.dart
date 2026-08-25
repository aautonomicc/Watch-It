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

Future<Directory> _defaultPostersDir() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/posters');
}

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
Future<void> saveUserDetails({
  required String lookupKey,
  required String title,
  int? year,
  String? overview,
  Value<String?> episodeLabel = const Value.absent(),
  Value<String?> posterFile = const Value.absent(),
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
          category: Value(existing?.category),
          episodeLabel: episodeLabel.present
              ? episodeLabel
              : Value(existing?.episodeLabel),
          posterFile: Value(newPoster),
          mediaType: Value(existing?.mediaType),
          tmdbId: Value(existing?.tmdbId),
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
