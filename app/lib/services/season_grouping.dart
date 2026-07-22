import '../models/media_list.dart';
import 'metadata.dart';

/// One item on the home wall: either a single (non-episode) entry or a
/// whole season of a show folded into one card.
sealed class HomeItem {
  const HomeItem();
}

class HomeEntry extends HomeItem {
  const HomeEntry(this.entry);

  final MediaEntry entry;
}

class HomeSeason extends HomeItem {
  const HomeSeason({
    required this.show,
    required this.season,
    required this.episodes,
  });

  /// Show name parsed from the file names — display fallback until the
  /// TMDB match (queried via any episode) supplies the canonical title.
  final String show;

  final int season;

  /// The season's entries, sorted by episode number.
  final List<MediaEntry> episodes;
}

class _SeasonBuilder {
  _SeasonBuilder(this.show, this.season, this.slot);

  final String show;
  final int season;

  /// Index in the items list where this season's card sits (the position
  /// of its first episode).
  final int slot;

  final episodes = <(int, MediaEntry)>[];
}

/// Fold a list's entries into home-wall items: entries whose file name
/// carries an `S01E02`/`1x02` marker group per (show, season), everything
/// else stays a single card. A group sits where its first episode
/// appeared; episodes inside a group sort by episode number.
List<HomeItem> groupSeasons(List<MediaEntry> entries) {
  final items = <HomeItem?>[];
  final bySeason = <String, _SeasonBuilder>{};
  for (final entry in entries) {
    final parsed = parseMediaName(entry.name);
    if (!parsed.isEpisode) {
      items.add(HomeEntry(entry));
      continue;
    }
    final key = '${parsed.title.toLowerCase()}|s${parsed.season}';
    var builder = bySeason[key];
    if (builder == null) {
      items.add(null); // reserve the slot; filled in below
      builder =
          bySeason[key] = _SeasonBuilder(parsed.title, parsed.season!, items.length - 1);
    }
    builder.episodes.add((parsed.episode!, entry));
  }
  for (final b in bySeason.values) {
    b.episodes.sort((x, y) => x.$1.compareTo(y.$1));
    items[b.slot] = HomeSeason(
      show: b.show,
      season: b.season,
      episodes: [for (final (_, e) in b.episodes) e],
    );
  }
  return items.cast<HomeItem>();
}

/// All of one show's seasons present in [entries], sorted by season
/// number — the season tiles on the show page. [show] matches
/// case-insensitively against the show name parsed from file names.
List<HomeSeason> showSeasons(List<MediaEntry> entries, String show) {
  final key = show.toLowerCase();
  final seasons = [
    for (final item in groupSeasons(entries))
      if (item is HomeSeason && item.show.toLowerCase() == key) item
  ];
  seasons.sort((a, b) => a.season.compareTo(b.season));
  return seasons;
}

/// Episode name from a `S01E02 · Name` label, or `null` when TMDB has not
/// supplied one (label is the bare marker, or missing).
String? episodeNameFromLabel(String? episodeLabel) {
  if (episodeLabel == null) return null;
  final sep = episodeLabel.indexOf('·');
  if (sep == -1) return null;
  final name = episodeLabel.substring(sep + 1).trim();
  return name.isEmpty ? null : name;
}
