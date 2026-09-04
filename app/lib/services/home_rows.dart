import '../models/media_list.dart';
import 'download_manager.dart';
import 'metadata.dart';
import 'season_grouping.dart';
import 'watch_state.dart';

/// One card in the home screen's Continue Watching row.
class ContinueItem {
  const ContinueItem({
    required this.entry,
    this.state,
    this.isNextUp = false,
    this.versions = const [],
  });

  final MediaEntry entry;

  /// The newest watch state across the title's versions; null for a
  /// next-up episode never played.
  final WatchState? state;

  /// True when [entry] is the next unwatched episode after a finished one
  /// (rather than a partially watched file being resumed).
  final bool isNextUp;

  /// Every upload of this title in the library when there is more than
  /// one (quality tiers fold into one card, like the wall); empty for
  /// the common single-upload case.
  final List<MediaEntry> versions;

  /// [versions], or just [entry] for the single-upload case.
  List<MediaEntry> get allVersions => versions.isEmpty ? [entry] : versions;
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
  final entries = _visibleEntries(lists);
  final entryByAddress = <String, MediaEntry>{};
  for (final e in entries) {
    entryByAddress.putIfAbsent(_normalize(e.address), () => e);
  }
  // Version folding: quality tiers of one title share a fold key (same
  // rule as the wall), so a title never shows two Continue cards, and
  // completing/resuming ANY tier counts for the whole title.
  final keys = VersionKeys(entries);
  final versionsByKey = <String, List<MediaEntry>>{};
  final keyByAddress = <String, String>{};
  for (final e in entryByAddress.values) {
    final key = keys.keyFor(parseMediaName(e.name));
    versionsByKey.putIfAbsent(key, () => []).add(e);
    keyByAddress[_normalize(e.address)] = key;
  }
  // Newest state per fold key ([states] is sorted newest first, so the
  // first one seen wins) — the read-time watch-point sync across tiers.
  final stateByKey = <String, WatchState>{};
  for (final s in states) {
    final key = keyByAddress[s.address];
    if (key != null) stateByKey.putIfAbsent(key, () => s);
  }

  final items = <ContinueItem>[];
  final seenShows = <String>{};
  final seenKeys = <String>{};
  for (final state in states) {
    if (items.length >= limit) break;
    final entry = entryByAddress[state.address];
    if (entry == null) continue; // removed from the library
    final key = keyByAddress[state.address]!;
    // Only the newest state of a title's versions makes its card.
    if (stateByKey[key] != state) continue;
    final parsed = parseMediaName(entry.name);
    final showKey =
        parsed.isEpisode ? 'show:${parsed.title.toLowerCase()}' : null;
    if (showKey != null && seenShows.contains(showKey)) continue;

    WatchState? stateOf(MediaEntry e) =>
        stateByKey[keyByAddress[_normalize(e.address)]];
    List<MediaEntry> versionsOf(MediaEntry e) {
      final versions = versionsByKey[keyByAddress[_normalize(e.address)]];
      return (versions?.length ?? 0) > 1 ? versions! : const [];
    }

    ContinueItem? item;
    if (state.resumable) {
      item = ContinueItem(
          entry: entry, state: state, versions: versionsOf(entry));
    } else if (state.completed && parsed.isEpisode) {
      // Finished an episode — surface the show's next unwatched one,
      // skipping over episodes already completed (on any tier) on an
      // earlier pass.
      var next = nextEpisode(lists, entry);
      while (next != null && (stateOf(next)?.completed ?? false)) {
        next = nextEpisode(lists, next);
      }
      if (next != null) {
        final nextState = stateOf(next);
        item = ContinueItem(
          entry: next,
          state: nextState,
          isNextUp: !(nextState?.resumable ?? false),
          versions: versionsOf(next),
        );
      }
    }
    if (item == null) continue;
    final itemKey = keyByAddress[_normalize(item.entry.address)]!;
    if (!seenKeys.add(itemKey)) continue;
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
