import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import 'season_grouping.dart';

String _normalize(String address) =>
    address.toLowerCase().replaceFirst('0x', '');

/// The user's favourited entries, as a set of normalized addresses
/// persisted in SharedPreferences — toggled by the heart on the detail
/// page, surfaced as the home screen's Favourites row. Kept apart from
/// the media lists on purpose: favouriting never edits a list, so it
/// cannot touch exports, the Media page, or the auto-mode split, and an
/// address whose entry leaves the library simply stops rendering (the
/// heart comes back if it is ever re-imported).
class FavouritesStore extends ChangeNotifier {
  /// Replaceable for tests (fresh instance per test).
  static FavouritesStore instance = FavouritesStore();

  static const _key = 'favourites_v1';

  final Set<String> _addresses = {};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key) ?? const [];
    if (stored.isEmpty) return;
    // Merge, don't replace — a heart toggled while the read was in
    // flight must survive.
    _addresses.addAll(stored.map(_normalize));
    notifyListeners();
  }

  bool isFavourite(String address) => _addresses.contains(_normalize(address));

  Future<void> toggle(String address) async {
    final addr = _normalize(address);
    if (!_addresses.add(addr)) _addresses.remove(addr);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _addresses.toList()..sort());
  }
}

/// The home screen's Favourites row: every favourited entry held in an
/// enabled list, in library order — movies as single cards, a show's
/// favourited episodes folded into one show card (like the wall). Empty
/// when nothing is favourited. [isFavourite] is injectable for tests;
/// the default asks the store.
List<HomeItem> favouriteItems(
  List<MediaList> lists, {
  bool Function(MediaEntry entry)? isFavourite,
}) {
  final check =
      isFavourite ?? (e) => FavouritesStore.instance.isFavourite(e.address);
  final seen = <String>{};
  final entries = [
    for (final l in lists)
      if (l.enabled)
        for (final e in l.entries)
          if (seen.add(_normalize(e.address)) && check(e)) e,
  ];
  return groupShows(entries);
}
