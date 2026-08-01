import 'package:flutter/foundation.dart';

import '../models/media_list.dart';
import 'app_settings.dart';
import 'metadata.dart';
import 'metadata_service.dart';

/// How the browsing surfaces (home wall, drawer, list pages) arrange the
/// library: the user's own lists, or two virtual lists derived from TMDB
/// media type. Chosen with the segmented control on the Media Lists page.
enum LibraryArrangement { userLists, autoByType }

/// Ids of the virtual auto-mode lists. The `auto:` prefix keeps them
/// apart from stored list ids — they are never persisted, edited,
/// renamed, or exported.
const kAutoMoviesListId = 'auto:movies';
const kAutoTvShowsListId = 'auto:tv-shows';

bool isAutoListId(String id) => id.startsWith('auto:');

/// Genre-chip label for entries with no matched genres.
const kUncategorised = 'Uncategorised';

/// In-memory mirror of the persisted arrangement choice so every mounted
/// surface (wall, drawer, Media Lists page) flips together the moment it
/// changes — listen like any ChangeNotifier.
class ArrangementStore extends ChangeNotifier {
  /// Replaceable for tests (fresh instance per test).
  static ArrangementStore instance = ArrangementStore();

  LibraryArrangement _value = LibraryArrangement.userLists;
  Set<String> _hiddenAutoIds = {};
  bool _loaded = false;

  LibraryArrangement get value => _value;
  bool get isAuto => _value == LibraryArrangement.autoByType;

  /// Virtual auto-mode lists hidden from home and the drawer (unchecked
  /// on the Media page in Auto by type). Keyed independently of the user
  /// lists' `enabled` flag — hiding TV Shows in auto mode leaves
  /// My-lists mode untouched.
  Set<String> get hiddenAutoIds => _hiddenAutoIds;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final stored = await AppSettings.libraryArrangement();
    final hidden = await AppSettings.autoHiddenLists();
    final changed = stored != _value || hidden.isNotEmpty;
    _value = stored;
    _hiddenAutoIds = hidden;
    if (changed) notifyListeners();
  }

  Future<void> set(LibraryArrangement value) async {
    _loaded = true;
    if (value == _value) return;
    _value = value;
    notifyListeners();
    await AppSettings.setLibraryArrangement(value);
  }

  Future<void> toggleAutoHidden(String id) async {
    if (!_hiddenAutoIds.add(id)) _hiddenAutoIds.remove(id);
    notifyListeners();
    await AppSettings.setAutoHiddenLists(_hiddenAutoIds);
  }
}

/// `'movie'` → Movies, `'tv'` → TV Shows, compared case-insensitively.
/// Unmatched/unknown types fall back to the parsed file name (an episode
/// marker means TV), so the split works keyless and offline too.
String autoListTitleForType(String? mediaType, String fileName) {
  return switch (mediaType?.toLowerCase()) {
    'tv' => 'TV Shows',
    'movie' => 'Movies',
    _ => parseMediaName(fileName).isEpisode ? 'TV Shows' : 'Movies',
  };
}

/// Auto-mode home for [entry], from the best metadata known right now
/// (the TMDB match wins over the filename guess as it lands).
String autoListTitleFor(MediaEntry entry) => autoListTitleForType(
    MetadataService.instance.metadataFor(entry).mediaType, entry.name);

/// Which virtual auto-mode list [entry] belongs to — the id form of
/// [autoListTitleFor], for filtering the home special rows.
String autoIdForEntry(MediaEntry entry) => autoListTitleFor(entry) == 'TV Shows'
    ? kAutoTvShowsListId
    : kAutoMoviesListId;

String _normalize(String address) =>
    address.toLowerCase().replaceFirst('0x', '');

/// The two virtual auto-mode lists: the union of entries from enabled
/// user lists, deduped by normalized address, split by media type.
/// Empty groups are dropped. Derived at display time — never stored.
List<MediaList> autoLists(List<MediaList> lists) {
  final seen = <String>{};
  final movies = <MediaEntry>[];
  final tv = <MediaEntry>[];
  for (final list in lists) {
    if (!list.enabled) continue;
    for (final entry in list.entries) {
      if (!seen.add(_normalize(entry.address))) continue;
      (autoIdForEntry(entry) == kAutoTvShowsListId ? tv : movies).add(entry);
    }
  }
  return [
    if (movies.isNotEmpty)
      MediaList(id: kAutoMoviesListId, title: 'Movies', entries: movies),
    if (tv.isNotEmpty)
      MediaList(id: kAutoTvShowsListId, title: 'TV Shows', entries: tv),
  ];
}

/// [autoLists] minus the ids in [hidden] — what auto mode actually shows
/// on the home wall and in the drawer (the Media page keeps the full,
/// unfiltered set so hidden rows stay visible there, unchecked).
List<MediaList> visibleAutoLists(List<MediaList> lists, Set<String> hidden) => [
      for (final l in autoLists(lists))
        if (!hidden.contains(l.id)) l,
    ];

/// The lists a drawer/list page can browse under [arrangement]: enabled
/// user lists, or the virtual Movies / TV Shows pair minus
/// [hiddenAutoIds].
List<MediaList> browsableLists(
    List<MediaList> lists, LibraryArrangement arrangement,
    {Set<String> hiddenAutoIds = const {}}) {
  if (arrangement == LibraryArrangement.autoByType) {
    return visibleAutoLists(lists, hiddenAutoIds);
  }
  return [
    for (final l in lists)
      if (l.enabled) l,
  ];
}

/// Individual genre names from a [MediaMetadata.category] value
/// (`'Horror · Thriller'` → `['Horror', 'Thriller']`); empty when
/// unmatched.
List<String> genreNames(String? category) {
  if (category == null) return const [];
  return [
    for (final part in category.split('·'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
