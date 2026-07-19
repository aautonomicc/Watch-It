import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';

/// Persists the user's media lists as a JSON blob in SharedPreferences.
/// Phase 0 stand-in for the SQLite (drift) store planned in ARCHITECTURE.md.
class LibraryStore {
  static const _key = 'media_lists_v1';

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
