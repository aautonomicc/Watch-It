import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import '../db/app_database.dart';
import '../models/intake_draft.dart';
import '../models/media_credits.dart';
import 'library_store.dart';
import 'media_credits_store.dart';

/// Durable storage for Add to W@tch intake drafts (db table
/// `intake_drafts`, schema 15). Everything here is device-local: no
/// network calls, no payments, no library writes. A draft only becomes
/// library data through the upload flow, after which
/// [carryCreditsIntoUploads] re-keys its credits onto the real file
/// addresses and the draft is consumed.
class IntakeStore {
  static Future<List<IntakeDraft>> loadAll() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(db.intakeDrafts)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    return [
      for (final row in rows)
        IntakeDraft(
          id: row.id,
          kind: row.kind,
          label: row.label,
          sourceUrl: row.sourceUrl,
          localPath: row.localPath,
          sizeBytes: row.sizeBytes,
          language: row.language,
          listTitle: row.listTitle,
          artworkFile: row.artworkFile,
          credits: MediaCredits.fromJson(
            jsonDecode(row.creditsJson) as Map<String, dynamic>,
          ),
          createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
        ),
    ];
  }

  static Future<IntakeDraft?> read(String id) async {
    final drafts = await loadAll();
    for (final d in drafts) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Validate and persist [draft] (insert or update by id). The only I/O
  /// is the local database — saving a draft can never upload, pay or
  /// publish anything.
  static Future<void> save(IntakeDraft draft) async {
    draft.validate();
    final db = await LibraryStore.database();
    await db
        .into(db.intakeDrafts)
        .insertOnConflictUpdate(
          IntakeDraftsCompanion.insert(
            id: draft.id,
            kind: draft.kind,
            label: draft.label,
            sourceUrl: Value(draft.sourceUrl),
            localPath: Value(draft.localPath),
            sizeBytes: Value(draft.sizeBytes),
            language: Value(draft.language),
            listTitle: Value(draft.listTitle),
            artworkFile: Value(draft.artworkFile),
            creditsJson: jsonEncode(draft.credits.toJson()),
            createdAt: draft.createdAt.millisecondsSinceEpoch,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  static Future<void> delete(String id) async {
    final db = await LibraryStore.database();
    await (db.delete(db.intakeDrafts)..where((t) => t.id.equals(id))).go();
  }

  /// Store cropped intake artwork in the shared posters dir and return
  /// its file name (`intake_<sha8>.img`). Existing bytes with the same
  /// content reuse the same name — content addressing, same as bundle
  /// poster seeding.
  static Future<String> saveArtwork(Uint8List bytes,
      {Future<Directory> Function()? postersDirProvider}) async {
    final name =
        'intake_${sha256.convert(bytes).toString().substring(0, 12)}.img';
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return name;
  }

  static Future<Directory> _defaultPostersDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/posters');
  }

  /// Read a draft's artwork bytes, or null when it is gone from disk.
  static Future<Uint8List?> readArtwork(String? artworkFile,
      {Future<Directory> Function()? postersDirProvider}) async {
    final name = artworkFile?.trim() ?? '';
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      return null;
    }
    final dir = await (postersDirProvider ?? _defaultPostersDir)();
    try {
      final file = File('${dir.path}/$name');
      if (!file.existsSync()) return null;
      return Uint8List.fromList(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }
}

/// After a real upload succeeds, move each draft's credits onto the
/// resulting file records (keyed by the manifest entry's XOR address)
/// and consume the drafts whose files fully uploaded. `uploads` pairs
/// the manifest entry's original source path with its resulting address
/// — tier encodes produce several outputs for one source, all carrying
/// the same credits. Only files whose draft still exists are touched;
/// gap-fill semantics ([MediaCreditsStore.seed]) keep any local record
/// that already exists for those addresses.
///
/// Returns the number of drafts consumed (fully uploaded and removed).
Future<int> carryCreditsIntoUploads(
  Iterable<({String source, String address})> uploads, {
  List<IntakeDraft>? draftsOverride,
}) async {
  final drafts = draftsOverride ?? await IntakeStore.loadAll();
  var consumed = 0;
  for (final draft in drafts) {
    if (!draft.isFile) continue;
    final path = draft.localPath?.trim() ?? '';
    if (path.isEmpty) continue;
    final mine = [
      for (final u in uploads)
        if (_sameSource(u.source, path)) u,
    ];
    if (mine.isEmpty) continue;
    for (final u in mine) {
      await MediaCreditsStore.seed(u.address, draft.credits);
    }
    await IntakeStore.delete(draft.id);
    consumed++;
  }
  return consumed;
}

/// Manifest sources arrive as absolute paths; a draft may have been
/// re-pointed at a copy. Compare canonically: exact match, or same
/// basename when one side is missing directories.
bool _sameSource(String manifestSource, String draftPath) {
  final a = manifestSource.trim();
  final b = draftPath.trim();
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final ab = a.replaceAll('\\', '/').split('/').last;
  final bb = b.replaceAll('\\', '/').split('/').last;
  return ab.isNotEmpty && ab == bb;
}
