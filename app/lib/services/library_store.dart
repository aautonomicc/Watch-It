import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import 'metadata.dart';

/// Persists the user's media lists as a JSON blob in SharedPreferences.
/// Phase 0 stand-in for the SQLite (drift) store planned in ARCHITECTURE.md.
class LibraryStore {
  static const _key = 'media_lists_v1';
  // v2: default movie re-uploaded under a new address (v1 seed dead).
  // v3: default replaced with the H.264 8-bit re-encode (Plex/Jellyfin
  // file name) — the AV1 10-bit webm was unplayable on most phones and
  // older desktops.
  static const _seededKey = 'defaults_seeded_v3';

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
