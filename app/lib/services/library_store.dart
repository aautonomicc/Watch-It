import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import 'metadata.dart';

/// Persists the user's media lists as a JSON blob in SharedPreferences.
/// Phase 0 stand-in for the SQLite (drift) store planned in ARCHITECTURE.md.
class LibraryStore {
  static const _key = 'media_lists_v1';
  static const _seededKey = 'defaults_seeded_v1';

  /// One-time seed of the built-in test movie so fresh (and upgraded)
  /// installs have something playable. Skipped when the user already has
  /// the address in a list; never re-added after the user deletes it.
  static Future<void> ensureDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seededKey) ?? false) return;
    final lists = await load();
    final alreadyThere = lists.any(
        (l) => l.entries.any((e) => e.address == kDefaultMovieAddress));
    if (!alreadyThere) {
      lists.add(const MediaList(
        id: 'default-test-movies',
        title: 'Test Movies',
        entries: [
          MediaEntry(
            name: 'Night Of The Living Dead (1968)',
            address: kDefaultMovieAddress,
          ),
        ],
      ));
      await save(lists);
    }
    await prefs.setBool(_seededKey, true);
  }

  static Future<List<MediaList>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => MediaList.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return [];
    }
  }

  static Future<void> save(List<MediaList> lists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(lists.map((l) => l.toJson()).toList()),
    );
  }
}
