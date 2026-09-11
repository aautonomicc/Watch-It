import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/media_credits.dart';
import '../models/media_list.dart';
import 'library_store.dart';

/// Credits use the file address, not a title/album lookup key: two recordings
/// with the same name can have different creators and licences. Renaming a
/// file or adding it to another list keeps its credit record intact.
class MediaCreditsStore {
  static String _address(String address) {
    final normalized = address.trim().toLowerCase().replaceFirst('0x', '');
    if (!looksLikeXorAddress(normalized)) {
      throw const FormatException('Invalid media address.');
    }
    return normalized;
  }

  static Future<MediaCredits?> read(String address) async {
    final db = await LibraryStore.database();
    final row = await (db.select(
      db.mediaCreditRecords,
    )..where((t) => t.address.equals(_address(address)))).getSingleOrNull();
    return row == null
        ? null
        : MediaCredits.fromJson(
            jsonDecode(row.recordJson) as Map<String, dynamic>,
          );
  }

  static Future<void> save(String address, MediaCredits credits) async {
    final validated = MediaCredits.fromJson(credits.toJson());
    final db = await LibraryStore.database();
    await db
        .into(db.mediaCreditRecords)
        .insertOnConflictUpdate(
          MediaCreditRecordsCompanion.insert(
            address: _address(address),
            recordJson: jsonEncode(validated.toJson()),
          ),
        );
  }

  /// Only import a record when that exact file has no local record. An empty
  /// local edit is deliberate too; an old bundle must not resurrect it.
  static Future<void> seed(String address, MediaCredits credits) async {
    final validated = MediaCredits.fromJson(credits.toJson());
    final db = await LibraryStore.database();
    await db
        .into(db.mediaCreditRecords)
        .insert(
          MediaCreditRecordsCompanion.insert(
            address: _address(address),
            recordJson: jsonEncode(validated.toJson()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }
}
