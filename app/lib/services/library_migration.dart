import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_store.dart';

/// One-time upgrade pass for installs that predate the datamap-first
/// entry model: every entry now requires its root map in the local
/// store (`/xor` no longer resolves over the network). A public file's
/// address == its derived address, so the entry rows themselves are
/// already correct — this pass only fills the map store for entries
/// never played or prefetched. Entries covered by the store (played
/// once, imported from a bundle, or the seeded demo's bundled asset)
/// cost one local lookup each.
///
/// The pass runs in the background on first launch after the upgrade,
/// is cancellable, and only records success when every entry is
/// covered — otherwise it retries on the next launch. Entries that
/// remain unresolved simply fast-fail at play time with the
/// "re-import" message until a later pass (or re-import) covers them.
class LibraryMigrator extends ChangeNotifier {
  LibraryMigrator({this.base});

  /// SharedPreferences flag: set only when a pass ends with every
  /// entry's map stored.
  static const prefsKey = 'datamap_migration_v1_done';

  final String? base;

  int current = 0;
  int total = 0;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Whether the one-time pass still needs to run.
  static Future<bool> pending() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(prefsKey) ?? false);
  }

  /// Run the pass: for every unique address in the library, check the
  /// local map store and resolve over the network when missing. Returns
  /// the number of entries still unresolved (0 marks the migration
  /// done), or null when it did not run (already done, no client, or
  /// nothing to migrate — which also marks it done).
  Future<int?> run() async {
    if (!await pending()) return null;
    final base = this.base;
    final lists = await LibraryStore.load();
    final addresses = <String, String>{}; // addr → a display name
    for (final list in lists) {
      for (final e in list.entries) {
        addresses.putIfAbsent(
            e.address.toLowerCase().replaceFirst('0x', ''), () => e.name);
      }
    }
    if (addresses.isEmpty) {
      await _markDone();
      return null;
    }
    if (base == null) return null;

    total = addresses.length;
    var failed = 0;
    final client = HttpClient();
    try {
      for (final entry in addresses.entries) {
        if (_cancelled) return total - current;
        current++;
        notifyListeners();
        if (await _isStored(client, base, entry.key)) continue;
        if (!await _resolve(client, base, entry.key)) failed++;
      }
    } finally {
      client.close(force: true);
    }
    if (failed == 0 && !_cancelled) await _markDone();
    return failed;
  }

  Future<void> _markDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, true);
  }

  /// Local-only check — `GET /rootmap` never touches the network.
  Future<bool> _isStored(HttpClient client, String base, String addr) async {
    try {
      final req = await client.getUrl(Uri.parse('$base/rootmap/$addr'));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Network resolve + persist via `/resolve` (one of the last call
  /// sites of the network map fetch — see the deprecation window in
  /// docs/PLAN-datamap-privacy.md).
  Future<bool> _resolve(HttpClient client, String base, String addr) async {
    try {
      final req = await client.getUrl(Uri.parse('$base/resolve/$addr'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return false;
      jsonDecode(body);
      return true;
    } catch (_) {
      return false;
    }
  }
}
