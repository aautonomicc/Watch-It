import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'metadata.dart';

/// Persists the user's media lists in SQLite (drift, see
/// db/app_database.dart). Earlier alphas stored them as a JSON blob in
/// SharedPreferences; that blob is imported once on first open, then
/// removed.
class LibraryStore {
  /// Legacy SharedPreferences key from the Phase 0 stand-in store.
  static const _legacyKey = 'media_lists_v1';
  // v2: default movie re-uploaded under a new address (v1 seed dead).
  // v3: default replaced with the H.264 8-bit re-encode (Plex/Jellyfin
  // file name) — the AV1 10-bit webm was unplayable on most phones and
  // older desktops.
  static const _seededKey = 'defaults_seeded_v3';

  static AppDatabase? _db;
  static Future<AppDatabase>? _opening;

  static Future<AppDatabase> _database() =>
      _opening ??= _open();

  static Future<AppDatabase> _open() async {
    final db = _db ??= AppDatabase();
    await _importLegacyPrefs(db);
    return db;
  }

  /// One-time import of the pre-SQLite SharedPreferences blob. Only fills
  /// an empty database (a populated one already imported, or was written
  /// by this version directly); the blob is removed either way.
  static Future<void> _importLegacyPrefs(AppDatabase db) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyKey);
    if (raw == null) return;
    final empty =
        await db.select(db.mediaLists).get().then((rows) => rows.isEmpty);
    if (empty && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final lists = decoded
            .map((e) => MediaList.fromJson(e as Map<String, dynamic>))
            .toList();
        await _write(db, lists);
      } on FormatException {
        // Corrupt blob: nothing to import.
      }
    }
    await prefs.remove(_legacyKey);
  }

  /// Point the store at a test database (typically
  /// `AppDatabase.forTesting(NativeDatabase.memory())`). Closes any
  /// previously injected database.
  @visibleForTesting
  static Future<void> useForTesting(AppDatabase db) async {
    await _db?.close();
    _db = db;
    _opening = null;
  }

  /// One-time seed of the built-in test movie so fresh (and upgraded)
  /// installs have something playable. Entries still pointing at a stale
  /// default address are rewritten to the current one. Skipped when the
  /// user already has the address in a list; never re-added after the user
  /// deletes it.
  static Future<void> ensureDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seededKey) ?? false) return;
    var lists = await load();
    var changed = false;
    if (lists.any((l) => l.entries
        .any((e) => kLegacyDefaultMovieAddresses.contains(e.address)))) {
      lists = [
        for (final l in lists)
          MediaList(
            id: l.id,
            title: l.title,
            entries: [
              for (final e in l.entries)
                kLegacyDefaultMovieAddresses.contains(e.address)
                    ? const MediaEntry(
                        name: kDefaultMovieName,
                        address: kDefaultMovieAddress,
                      )
                    : e,
            ],
          ),
      ];
      changed = true;
    }
    if (!lists.any(
        (l) => l.entries.any((e) => e.address == kDefaultMovieAddress))) {
      lists.add(const MediaList(
        id: 'default-test-movies',
        title: 'Test Movies',
        entries: [
          MediaEntry(
            name: kDefaultMovieName,
            address: kDefaultMovieAddress,
          ),
        ],
      ));
      changed = true;
    }
    if (changed) await save(lists);
    await prefs.setBool(_seededKey, true);
  }

  static Future<List<MediaList>> load() async {
    final db = await _database();
    final listRows = await (db.select(db.mediaLists)
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();
    final entryRows = await (db.select(db.mediaEntries)
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();
    final entriesByList = <String, List<MediaEntry>>{};
    for (final row in entryRows) {
      entriesByList
          .putIfAbsent(row.listId, () => [])
          .add(MediaEntry(name: row.name, address: row.address));
    }
    return [
      for (final row in listRows)
        MediaList(
          id: row.id,
          title: row.title,
          entries: entriesByList[row.id] ?? const [],
        ),
    ];
  }

  static Future<void> save(List<MediaList> lists) async {
    final db = await _database();
    await _write(db, lists);
  }

  /// Full-replace write, mirroring the store's whole-library API.
  static Future<void> _write(AppDatabase db, List<MediaList> lists) {
    return db.transaction(() async {
      await db.delete(db.mediaEntries).go();
      await db.delete(db.mediaLists).go();
      for (final (listPos, list) in lists.indexed) {
        await db.into(db.mediaLists).insert(MediaListsCompanion.insert(
              id: list.id,
              title: list.title,
              position: listPos,
            ));
        for (final (entryPos, entry) in list.entries.indexed) {
          await db.into(db.mediaEntries).insert(MediaEntriesCompanion.insert(
                listId: list.id,
                name: entry.name,
                address: entry.address,
                position: entryPos,
              ));
        }
      }
    });
  }
}
