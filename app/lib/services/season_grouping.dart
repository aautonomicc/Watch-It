import '../models/media_list.dart';
import 'metadata.dart';

/// One item on the home wall: either a single (non-episode) entry or a
/// whole season of a show folded into one card.
sealed class HomeItem {
  const HomeItem();
}

class HomeEntry extends HomeItem {
  const HomeEntry(this.entry, {this.versions = const []});

  final MediaEntry entry;

  /// Every upload of this title held in the library (same parsed
  /// [ParsedName.lookupKey], different addresses) when there is more than
  /// one — e.g. a 480p and a 1080p copy of the same film. Empty for the
  /// common single-upload case; [entry] is always the first version.
  final List<MediaEntry> versions;

  /// [versions], or just [entry] for the single-upload case.
  List<MediaEntry> get allVersions => versions.isEmpty ? [entry] : versions;
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

/// All of one show's seasons folded into a single wall card (the home
/// screen shows one tile per show, not per season).
class HomeShow extends HomeItem {
  const HomeShow({required this.show, required this.seasons});

  /// Show name parsed from the file names (display fallback, as on
  /// [HomeSeason]).
  final String show;

  /// The show's seasons present in the list, sorted by season number;
  /// never empty.
  final List<HomeSeason> seasons;

  int get episodeCount =>
      seasons.fold(0, (sum, s) => sum + s.episodes.length);
}

/// An album folded into a single wall card: every track of one release
/// (same [AlbumKeys] fold key — the `{mbid-...}` tag, or album/year with
/// the per-track artist deliberately left out so compilations fold).
/// Track `NN` plays the role `SxxEyy` does for TV.
class HomeAlbum extends HomeItem {
  const HomeAlbum({
    required this.artist,
    required this.album,
    required this.tracks,
    this.year,
    this.isCompilation = false,
  });

  /// Artist/album names parsed from the file names — display fallback
  /// (music has no TMDB-style canonical-title fetch; CLI-written names
  /// already carry the MusicBrainz canonical data). An album whose
  /// tracks credit different artists reads `Various Artists`.
  final String artist;
  final String album;

  /// Release year parsed from the file names, when present.
  final int? year;

  /// True for compilations — a `Various Artists` credit, or tracks
  /// whose parsed artists disagree. Compilations never fold under an
  /// artist card ([groupShows]); they stand alone on the wall.
  final bool isCompilation;

  /// The album's entries, sorted by disc then track number.
  final List<MediaEntry> tracks;
}

/// All of one artist's albums folded into a single wall card (the music
/// mirror of [HomeShow]): once an artist has two or more albums in the
/// list they share one tile that opens the artist page. Single-album
/// artists and compilations stay as [HomeAlbum] cards.
class HomeArtist extends HomeItem {
  const HomeArtist({required this.artist, required this.albums});

  /// Artist name parsed from the file names (display fallback, as on
  /// [HomeAlbum]).
  final String artist;

  /// The artist's albums present in the list, sorted by year then
  /// title; never fewer than two.
  final List<HomeAlbum> albums;

  int get trackCount => albums.fold(0, (sum, a) => sum + a.tracks.length);
}

class _AlbumBuilder {
  _AlbumBuilder(this.artist, this.album, this.slot);

  final String artist;
  final String album;

  /// Index in the items list where this album's card sits (the position
  /// of its first track).
  final int slot;

  final tracks = <(int, int, MediaEntry)>[];

  /// Distinct per-track artist credits (lowercased) — more than one
  /// marks the album a compilation.
  final artists = <String>{};

  /// First parsed release year seen on a track.
  int? year;
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

class _VersionBuilder {
  _VersionBuilder(this.slot);

  /// Index in the items list where this title's card sits (the position
  /// of its first upload).
  final int slot;

  final entries = <MediaEntry>[];
  final addresses = <String>{};
}

/// Fold keys for same-title version grouping. Normally an entry folds by
/// its parsed [ParsedName.lookupKey], but that key is imdb-id-based only
/// when the file name carries an id tag — a loosely named copy
/// (`Title (Year).mp4`) of a Plex/Jellyfin-named upload would land in a
/// different group and show as a second card. So an entry with no imdb
/// id adopts the key of the imdb-tagged entry sharing its title (and
/// year, when it has one), as long as exactly one imdb id claims that
/// title — two different ids (remakes) never alias.
class VersionKeys {
  VersionKeys(Iterable<MediaEntry> entries) {
    for (final e in entries) {
      final p = parseMediaName(e.name);
      if (p.isEpisode || p.imdbId == null) continue;
      final title = p.title.toLowerCase();
      if (title.isEmpty) continue;
      _claim(_byTitle, title, p.lookupKey);
      if (p.year != null) _claim(_byTitleYear, '$title|${p.year}', p.lookupKey);
    }
  }

  /// `''` marks a title claimed by two different imdb ids — never alias.
  final _byTitle = <String, String>{};
  final _byTitleYear = <String, String>{};

  /// The fold key for [parsed]: its own lookupKey, or the unambiguous
  /// imdb-tagged sibling's.
  String keyFor(ParsedName parsed) {
    if (parsed.isEpisode || parsed.imdbId != null) return parsed.lookupKey;
    final title = parsed.title.toLowerCase();
    final alias = parsed.year != null
        ? _byTitleYear['$title|${parsed.year}']
        : _byTitle[title];
    if (alias == null || alias.isEmpty) return parsed.lookupKey;
    return alias;
  }
}

/// `''` marks a key claimed by two different values — never alias.
void _claim(Map<String, String> map, String key, String value) {
  final held = map[key];
  if (held == null) {
    map[key] = value;
  } else if (held != value) {
    map[key] = '';
  }
}

/// Fold keys for album grouping. A track's parsed
/// [ParsedName.lookupKey] embeds the per-track artist, so tracks of one
/// album that credit different artists — a hand-renamed compilation, the
/// natural way to organise loose tracks — would each get their own wall
/// card that all claim the same album. Tracks therefore cluster WITHOUT
/// the artist: by `{mbid-...}` tag when present, else by album title +
/// year. Missing pieces adopt an unambiguous sibling's (a year-less
/// track takes the only year its album name carries; an untagged track
/// takes the only mbid claiming its album title/year, mirroring
/// [VersionKeys] for movies). Safety guard: when a cluster holds the
/// same track number credited to two different artists it is really two
/// same-named albums (two "Greatest Hits"), and the cluster splits back
/// out per artist — except mbid clusters, where the tag says one release
/// by declaration.
class AlbumKeys {
  AlbumKeys(Iterable<MediaEntry> entries) {
    final parsed = <ParsedName>[];
    for (final e in entries) {
      final p = parseMediaName(e.name);
      if (!p.isTrack) continue;
      parsed.add(p);
      final album = p.title.trim().toLowerCase();
      if (p.releaseMbid != null) {
        _claim(_mbidByAlbum, album, 'mbid:${p.releaseMbid}');
        if (p.year != null) {
          _claim(_mbidByAlbumYear, '$album|${p.year}', 'mbid:${p.releaseMbid}');
        }
      }
      if (p.year != null) _claim(_yearByAlbum, album, '${p.year}');
    }
    // A cluster whose track number is credited to two different artists
    // is two distinct albums sharing a name — split it per artist.
    final artistsByNumber = <String, Map<String, Set<String>>>{};
    for (final p in parsed) {
      artistsByNumber
          .putIfAbsent(_clusterFor(p), () => {})
          .putIfAbsent('${p.disc ?? 1}-${p.track}', () => {})
          .add(p.artist!.trim().toLowerCase());
    }
    for (final e in artistsByNumber.entries) {
      if (e.key.startsWith('mbid:')) continue;
      if (e.value.values.any((artists) => artists.length > 1)) {
        _split.add(e.key);
      }
    }
  }

  final _mbidByAlbum = <String, String>{};
  final _mbidByAlbumYear = <String, String>{};
  final _yearByAlbum = <String, String>{};
  final _split = <String>{};

  String _clusterFor(ParsedName p) {
    if (p.releaseMbid != null) return 'mbid:${p.releaseMbid}';
    final album = p.title.trim().toLowerCase();
    final mbid = p.year != null
        ? _mbidByAlbumYear['$album|${p.year}']
        : _mbidByAlbum[album];
    if (mbid != null && mbid.isNotEmpty) return mbid;
    var year = '${p.year ?? ''}';
    if (year.isEmpty) {
      final adopted = _yearByAlbum[album];
      if (adopted != null && adopted.isNotEmpty) year = adopted;
    }
    return 'music:$album:$year';
  }

  /// The cluster BEFORE the same-number-different-artist split guard —
  /// what the fold would be if track numbers didn't collide. The album
  /// rename's collision check compares clusters so a would-be split is
  /// caught and refused instead of quietly splitting the album apart.
  String clusterFor(ParsedName parsed) => _clusterFor(parsed);

  /// The fold key for track [parsed]: its cluster, plus the artist when
  /// the cluster proved to be two same-named albums.
  String keyFor(ParsedName parsed) {
    final cluster = _clusterFor(parsed);
    if (!_split.contains(cluster)) return cluster;
    return '$cluster:${parsed.artist!.trim().toLowerCase()}';
  }
}

/// Fold a list's entries into home-wall items: entries whose file name
/// carries an `S01E02`/`1x02` marker group per (show, season); music
/// tracks group per album ([HomeAlbum]); other entries get one card per
/// title, with multiple uploads of the same title (same parsed lookup
/// key — e.g. a 480p and a 1080p copy) folded into a single [HomeEntry]
/// carrying all versions. A group sits where its first entry appeared;
/// episodes/tracks inside a group sort by their number, versions keep
/// library order.
List<HomeItem> groupSeasons(List<MediaEntry> entries) {
  final items = <HomeItem?>[];
  final bySeason = <String, _SeasonBuilder>{};
  final byTitle = <String, _VersionBuilder>{};
  final byAlbum = <String, _AlbumBuilder>{};
  final keys = VersionKeys(entries);
  final albumKeys = AlbumKeys(entries);
  for (final entry in entries) {
    final parsed = parseMediaName(entry.name);
    if (parsed.isTrack) {
      final key = albumKeys.keyFor(parsed);
      var builder = byAlbum[key];
      if (builder == null) {
        items.add(null); // reserve the slot; filled in below
        builder = byAlbum[key] =
            _AlbumBuilder(parsed.artist!, parsed.title, items.length - 1);
      }
      builder.tracks.add((parsed.disc ?? 1, parsed.track!, entry));
      builder.artists.add(parsed.artist!.trim().toLowerCase());
      builder.year ??= parsed.year;
      continue;
    }
    if (!parsed.isEpisode) {
      final key = keys.keyFor(parsed);
      var builder = byTitle[key];
      if (builder == null) {
        items.add(null); // reserve the slot; filled in below
        builder = byTitle[key] = _VersionBuilder(items.length - 1);
      }
      final addr = entry.address.toLowerCase().replaceFirst('0x', '');
      if (builder.addresses.add(addr)) builder.entries.add(entry);
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
  for (final b in byTitle.values) {
    items[b.slot] = HomeEntry(
      b.entries.first,
      versions: b.entries.length > 1 ? b.entries : const [],
    );
  }
  for (final b in byAlbum.values) {
    b.tracks.sort((x, y) =>
        x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    // Tracks crediting different artists mark a compilation — so does
    // an explicit Various Artists credit (the naming convention for
    // compilations, docs/NAMING.md).
    final mixed = b.artists.length > 1;
    final artist = mixed ? 'Various Artists' : b.artist;
    items[b.slot] = HomeAlbum(
      artist: artist,
      album: b.album,
      year: b.year,
      isCompilation:
          mixed || artist.trim().toLowerCase() == 'various artists',
      tracks: [for (final (_, _, e) in b.tracks) e],
    );
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

/// Fold [groupSeasons]' groups further, so every season of one show
/// shares a single [HomeShow] card and — the music mirror — every album
/// of one artist shares a [HomeArtist] card once the artist has two or
/// more albums in the list. Compilations ([HomeAlbum.isCompilation])
/// and single-album artists keep their own album card. A group's card
/// sits where its first entry appeared; seasons sort by number, an
/// artist's albums by year then title.
List<HomeItem> groupShows(List<MediaEntry> entries) {
  final items = <HomeItem?>[];
  final slotByShow = <String, int>{};
  final seasonsByShow = <String, List<HomeSeason>>{};
  final slotByArtist = <String, int>{};
  final albumsByArtist = <String, List<HomeAlbum>>{};
  for (final item in groupSeasons(entries)) {
    if (item is HomeSeason) {
      final key = item.show.toLowerCase();
      final seasons = seasonsByShow.putIfAbsent(key, () {
        slotByShow[key] = items.length;
        items.add(null); // reserve the slot; filled in below
        return [];
      });
      seasons.add(item);
    } else if (item is HomeAlbum && !item.isCompilation) {
      final key = item.artist.trim().toLowerCase();
      final albums = albumsByArtist.putIfAbsent(key, () {
        slotByArtist[key] = items.length;
        items.add(null); // reserve the slot; filled in below
        return [];
      });
      albums.add(item);
    } else {
      items.add(item);
    }
  }
  for (final entry in slotByShow.entries) {
    final seasons = seasonsByShow[entry.key]!
      ..sort((a, b) => a.season.compareTo(b.season));
    items[entry.value] =
        HomeShow(show: seasons.first.show, seasons: seasons);
  }
  for (final entry in slotByArtist.entries) {
    final albums = albumsByArtist[entry.key]!;
    // Folding starts at the second album — one album is just an album.
    if (albums.length == 1) {
      items[entry.value] = albums.single;
      continue;
    }
    albums.sort((a, b) {
      final ya = a.year ?? 1 << 30;
      final yb = b.year ?? 1 << 30;
      return ya != yb
          ? ya.compareTo(yb)
          : a.album.toLowerCase().compareTo(b.album.toLowerCase());
    });
    items[entry.value] =
        HomeArtist(artist: albums.first.artist, albums: albums);
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
