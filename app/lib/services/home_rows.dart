import '../models/media_list.dart';
import 'download_manager.dart';
import 'metadata.dart';
import 'season_grouping.dart';
import 'watch_state.dart';

/// One card in the home screen's Continue Watching row.
class ContinueItem {
  const ContinueItem({required this.entry, this.state, this.isNextUp = false});

  final MediaEntry entry;

  /// The entry's own watch state; null for a next-up episode never played.
  final WatchState? state;

  /// True when [entry] is the next unwatched episode after a finished one
  /// (rather than a partially watched file being resumed).
  final bool isNextUp;
}

String _normalize(String address) =>
    address.toLowerCase().replaceFirst('0x', '');

List<MediaEntry> _visibleEntries(List<MediaList> lists) => [
      for (final l in lists)
        if (l.enabled) ...l.entries,
    ];

/// The episode after [entry] within its show: next episode number in the
/// same season, else the first episode of the next season present in the
/// library. Null for movies, unknown shows, and final episodes.
MediaEntry? nextEpisode(List<MediaList> lists, MediaEntry entry) {
  final parsed = parseMediaName(entry.name);
  if (!parsed.isEpisode) return null;
  final seasons = showSeasons(_visibleEntries(lists), parsed.title);
  for (var i = 0; i < seasons.length; i++) {
    if (seasons[i].season != parsed.season) continue;
    for (final ep in seasons[i].episodes) {
      if ((parseMediaName(ep.name).episode ?? 0) > parsed.episode!) return ep;
    }
    if (i + 1 < seasons.length) return seasons[i + 1].episodes.first;
    return null;
  }
  return null;
}

/// The home screen's Continue Watching row: partially watched files to
/// resume plus, for each show whose latest activity finished an episode,
/// the next unwatched episode ("next up"). One card per show, most
/// recent activity first, capped at [limit].
Future<List<ContinueItem>> continueWatching(
  List<MediaList> lists, {
  WatchStateStore? store,
  int limit = 10,
}) async {
  final states = await (store ?? WatchStateStore.instance).all();
  final byAddress = <String, WatchState>{
    for (final s in states) s.address: s,
  };
  final entries = _visibleEntries(lists);
  final entryByAddress = <String, MediaEntry>{};
  for (final e in entries) {
    entryByAddress.putIfAbsent(_normalize(e.address), () => e);
  }

  final items = <ContinueItem>[];
  final seenShows = <String>{};
  final seenAddresses = <String>{};
  for (final state in states) {
    if (items.length >= limit) break;
    final entry = entryByAddress[state.address];
    if (entry == null) continue; // removed from the library
    final parsed = parseMediaName(entry.name);
    final showKey =
        parsed.isEpisode ? 'show:${parsed.title.toLowerCase()}' : null;
    if (showKey != null && seenShows.contains(showKey)) continue;

    ContinueItem? item;
    if (state.resumable) {
      item = ContinueItem(entry: entry, state: state);
    } else if (state.completed && parsed.isEpisode) {
      // Finished an episode — surface the show's next unwatched one,
      // skipping over episodes already completed on an earlier pass.
      var next = nextEpisode(lists, entry);
      while (next != null &&
          (byAddress[_normalize(next.address)]?.completed ?? false)) {
        next = nextEpisode(lists, next);
      }
      if (next != null) {
        final nextState = byAddress[_normalize(next.address)];
        item = ContinueItem(
          entry: next,
          state: nextState,
          isNextUp: !(nextState?.resumable ?? false),
        );
      }
    }
    if (item == null) continue;
    if (!seenAddresses.add(_normalize(item.entry.address))) continue;
    if (showKey != null) seenShows.add(showKey);
    items.add(item);
  }
  return items;
}

/// The home screen's Downloads row: everything fully downloaded, in
/// library order — movies as single cards, a show's downloaded episodes
/// folded into one show card (like the wall). Empty when nothing is
/// downloaded. [isDownloaded] is injectable for tests; the default asks
/// the download manager.
List<HomeItem> downloadedItems(
  List<MediaList> lists, {
  bool Function(MediaEntry entry)? isDownloaded,
}) {
  final check = isDownloaded ??
      (e) =>
          DownloadManager.instance.taskFor(e.address)?.status ==
          DownloadStatus.done;
  final seen = <String>{};
  final entries = [
    for (final e in _visibleEntries(lists))
      if (seen.add(_normalize(e.address)) && check(e)) e,
  ];
  return groupShows(entries);
}

/// The home screen's Recently Added row: newest library additions first,
/// with all episodes of one show folded into a single show card (like the
/// wall). Entries whose add time predates the addedAt column are skipped.
List<HomeItem> recentlyAdded(List<MediaList> lists, {int limit = 10}) {
  final entries = _visibleEntries(lists);
  final byAddress = <String, MediaEntry>{};
  for (final e in entries) {
    if ((e.addedAt ?? 0) <= 0) continue;
    final existing = byAddress[_normalize(e.address)];
    if (existing == null || (existing.addedAt ?? 0) < e.addedAt!) {
      byAddress[_normalize(e.address)] = e;
    }
  }
  final sorted = byAddress.values.toList()
    ..sort((a, b) => b.addedAt!.compareTo(a.addedAt!));
  return groupShows(sorted).take(limit).toList();
}
