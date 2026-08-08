import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'metadata.dart';
import 'seed_catalog.dart';

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
  // v4: single default movie replaced with the full public-domain seed
  // catalog (kSeedLists) — v3-seeded installs gain the new titles on
  // upgrade, with the old default-movie address migrated in place.
  static const _seededKey = 'defaults_seeded_v4';

  /// Id of the seeded default list ("Movies"; "Test Movies" before
  /// alpha.26 — [ensureDefaults] renames it in place).
  static const _defaultListId = 'default-test-movies';

  static AppDatabase? _db;
  static Future<AppDatabase>? _opening;

  static Future<AppDatabase> _database() =>
      _opening ??= _open();

  /// The app database, opened (and legacy-imported) on first use. Shared
  /// with [MetadataService] for the metadata cache table.
  static Future<AppDatabase> database() => _database();

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

  /// Close the database (used by the factory reset just before the app
  /// data directory is wiped and the app exits).
  static Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    await db?.close();
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

  /// One-time seed of the built-in public-domain catalog ([kSeedLists])
  /// so fresh (and upgraded) installs have something playable. Entries
  /// still pointing at a stale default-movie address are rewritten to the
  /// current one. An entry the user already has is never duplicated, and
  /// nothing is re-added after the user deletes it.
  static Future<void> ensureDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    var lists = await load();
    var changed = false;
    // Pre-alpha.26 installs seeded the list as "Test Movies"; rename it
    // in place. A user rename to anything else is left alone.
    final stale = lists.indexWhere(
        (l) => l.id == _defaultListId && l.title == 'Test Movies');
    if (stale != -1) {
      lists[stale] = lists[stale].copyWith(title: 'Movies');
      changed = true;
    }
    if (prefs.getBool(_seededKey) ?? false) {
      if (changed) await save(lists);
      await ensureSeedFileInfo();
      return;
    }
    if (lists.any((l) => l.entries
        .any((e) => kLegacyDefaultMovieAddresses.contains(e.address)))) {
      lists = [
        for (final l in lists)
          l.copyWith(
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
    // Seed every catalog entry the library doesn't hold yet, merging
    // into an existing list with the seed list's id (the pre-v4 default
    // list keeps user renames), else creating the list.
    final have = {
      for (final l in lists)
        for (final e in l.entries) e.address.toLowerCase(),
    };
    for (final seed in kSeedLists) {
      final fresh = [
        for (final e in seed.entries)
          if (!have.contains(e.address))
            MediaEntry(
              name: e.name,
              address: e.address,
              sizeBytes: e.sizeBytes,
              videoInfo: e.videoInfo,
            ),
      ];
      if (fresh.isEmpty) continue;
      final i = lists.indexWhere((l) => l.id == seed.id);
      if (i != -1) {
        lists[i] =
            lists[i].copyWith(entries: [...lists[i].entries, ...fresh]);
      } else {
        lists.add(MediaList(id: seed.id, title: seed.title, entries: fresh));
      }
      changed = true;
    }
    if (changed) await save(lists);
    await prefs.setBool(_seededKey, true);
    await ensureSeedFileInfo();
  }

  /// One-time backfill of file size + format info onto catalog entries
  /// held by installs that seeded before the columns existed (a fresh
  /// seed carries the info directly). Separate flag from [_seededKey]
  /// on purpose: it must also run on already-seeded libraries, and it
  /// never re-adds entries — it only annotates what is already there.
  static const _fileInfoKey = 'seed_fileinfo_v1';

  static Future<void> ensureSeedFileInfo() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_fileInfoKey) ?? false) return;
    for (final seed in kSeedLists) {
      for (final e in seed.entries) {
        await noteEntryInfo(e.address,
            sizeBytes: e.sizeBytes, videoInfo: e.videoInfo);
      }
    }
    await prefs.setBool(_fileInfoKey, true);
  }

  /// Record what is known about the file behind [address] — its exact
  /// size and/or video-format label — on every list entry holding it.
  /// A null argument leaves that column untouched.
  static Future<void> noteEntryInfo(String address,
      {int? sizeBytes, String? videoInfo}) async {
    if (sizeBytes == null && videoInfo == null) return;
    final db = await _database();
    final addr = address.toLowerCase().replaceFirst('0x', '');
    await (db.update(db.mediaEntries)
          ..where((t) => t.address.lower().equals(addr)))
        .write(MediaEntriesCompanion(
      sizeBytes: sizeBytes != null ? Value(sizeBytes) : const Value.absent(),
      videoInfo: videoInfo != null ? Value(videoInfo) : const Value.absent(),
    ));
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
    // addedAt loads verbatim — 0 (pre-column row, add time unknown) must
    // survive the round-trip, not get stamped as new on the next save.
    for (final row in entryRows) {
      entriesByList.putIfAbsent(row.listId, () => []).add(MediaEntry(
            name: row.name,
            address: row.address,
            addedAt: row.addedAt,
            sizeBytes: row.sizeBytes,
            videoInfo: row.videoInfo,
          ));
    }
    return [
      for (final row in listRows)
        MediaList(
          id: row.id,
          title: row.title,
          entries: entriesByList[row.id] ?? const [],
          enabled: row.enabled,
        ),
    ];
  }

  static Future<void> save(List<MediaList> lists) async {
    final db = await _database();
    await _write(db, lists);
  }

  /// Full-replace write, mirroring the store's whole-library API. Entries
  /// without an add time (created by the UI/import this session) are
  /// stamped now; loaded entries carry theirs through unchanged.
  static Future<void> _write(AppDatabase db, List<MediaList> lists) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction(() async {
      await db.delete(db.mediaEntries).go();
      await db.delete(db.mediaLists).go();
      for (final (listPos, list) in lists.indexed) {
        await db.into(db.mediaLists).insert(MediaListsCompanion.insert(
              id: list.id,
              title: list.title,
              position: listPos,
              enabled: Value(list.enabled),
            ));
        for (final (entryPos, entry) in list.entries.indexed) {
          await db.into(db.mediaEntries).insert(MediaEntriesCompanion.insert(
                listId: list.id,
                name: entry.name,
                address: entry.address,
                position: entryPos,
                addedAt: Value(entry.addedAt ?? now),
                sizeBytes: Value(entry.sizeBytes),
                videoInfo: Value(entry.videoInfo),
              ));
        }
      }
    });
  }
}
