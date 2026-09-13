import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_search.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../services/version_choice.dart';
import '../theme/tokens.dart';

/// The playlist "Add media" picker as a full-screen page (2026-09-13,
/// replaces the old 420×460 flat-list dialog that made large libraries
/// impractical): a search field over the whole candidate pool (the home
/// search's [SearchIndex] — ranked, diacritic-folded, debounced), the
/// type chips, and the library grouped the way the wall folds it —
/// artist → album → track and show → season → episode as expansion
/// tiles whose tri-state checkboxes select a whole album or season in
/// one tap. Quality tiers fold into one row; confirming adds each
/// picked title's preferred version, in tree order (so a season lands
/// in episode order).
///
/// Pops with the selected entries; the caller appends them to the
/// playlist.
class PlaylistAddScreen extends StatefulWidget {
  const PlaylistAddScreen({
    super.key,
    required this.pool,
    required this.playlistTitle,
  });

  /// Candidate entries (the library minus what the playlist already
  /// holds), deduplicated by address.
  final List<MediaEntry> pool;

  final String playlistTitle;

  @override
  State<PlaylistAddScreen> createState() => _PlaylistAddScreenState();
}

/// One selectable row: a title's representative entry plus every upload
/// of it in the pool (quality tiers) — confirming adds the preferred
/// version, mirroring how Up-next and the season buttons pick.
typedef _Unit = ({MediaEntry rep, List<MediaEntry> versions});

class _PlaylistAddScreenState extends State<PlaylistAddScreen> {
  static const _debounce = Duration(milliseconds: 150);

  final _query = TextEditingController();
  Timer? _debounceTimer;
  List<SearchResult> _results = const [];

  /// The pool folded like the wall — built once; the pool never changes
  /// while the page is open.
  late final List<HomeItem> _items = groupShows(widget.pool);

  /// Selectable units in canonical (tree) order + lookup by the
  /// representative's normalized address.
  late final List<_Unit> _units = _buildUnits();
  late final Map<String, _Unit> _unitByKey = {
    for (final u in _units) _keyOf(u.rep): u,
  };

  final _picked = <String>{};
  String _filter = 'All';

  static String _keyOf(MediaEntry e) =>
      e.address.toLowerCase().replaceFirst('0x', '');

  List<_Unit> _buildUnits() {
    final units = <_Unit>[];
    void addUnit(MediaEntry rep, List<MediaEntry> versions) =>
        units.add((rep: rep, versions: versions));
    for (final item in _items) {
      switch (item) {
        case HomeEntry():
          addUnit(item.entry, item.allVersions);
        case HomeShow():
          for (final season in item.seasons) {
            for (final ep in season.episodes) {
              addUnit(ep, season.versionsOf(ep));
            }
          }
        case HomeAlbum():
          for (final track in item.tracks) {
            addUnit(track, [track]);
          }
        case HomeArtist():
          for (final album in item.albums) {
            for (final track in album.tracks) {
              addUnit(track, [track]);
            }
          }
        case HomeSeason():
          break; // groupShows never yields bare seasons
      }
    }
    return units;
  }

  /// Which chip an item files under.
  static String _kindOfItem(HomeItem item) => switch (item) {
        HomeShow() => 'Episodes',
        HomeAlbum() || HomeArtist() => 'Music',
        HomeEntry(:final entry) =>
          parseMediaName(entry.name).isAudio ? 'Music' : 'Movies',
        HomeSeason() => 'Episodes',
      };

  Set<String> get _kinds => {for (final i in _items) _kindOfItem(i)};

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryEdited);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryEdited() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _runQuery);
  }

  void _runQuery() {
    if (!mounted) return;
    final raw = _query.text;
    if (raw.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    // Rebuilt per query rather than tracking metadata invalidation —
    // the scan is in-memory and cheap (home search precedent).
    final index = SearchIndex.build(
      [MediaList(id: 'pool', title: 'pool', entries: widget.pool)],
      episodeName: (e) => episodeNameFromLabel(
          MetadataService.instance.metadataFor(e).episodeLabel),
    );
    setState(() => _results = index.query(raw));
  }

  void _toggle(String key, bool on) => setState(() {
        on ? _picked.add(key) : _picked.remove(key);
      });

  /// Group checkbox value over [keys]: true = all picked, false = none,
  /// null = some (the tri-state "partial" mark).
  bool? _groupValue(Iterable<String> keys) {
    var any = false;
    var all = true;
    for (final k in keys) {
      _picked.contains(k) ? any = true : all = false;
    }
    if (!any) return false;
    return all ? true : null;
  }

  void _toggleGroup(List<String> keys) => setState(() {
        // Anything unpicked → pick the whole group; fully picked →
        // clear it (tapping a partial group completes it).
        if (keys.every(_picked.contains)) {
          _picked.removeAll(keys);
        } else {
          _picked.addAll(keys);
        }
      });

  void _confirm() {
    final selection = <MediaEntry>[
      for (final u in _units)
        if (_picked.contains(_keyOf(u.rep))) preferredVersion(u.versions),
    ];
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Add to "${widget.playlistTitle}"',
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: FilledButton(
                onPressed: _picked.isEmpty ? null : _confirm,
                child: Text(_picked.length <= 1
                    ? 'Add'
                    : 'Add ${_picked.length}'),
              ),
            ),
          ),
        ],
      ),
      // Repaint as cached metadata (episode names, artwork) lands.
      body: ListenableBuilder(
        listenable: MetadataService.instance,
        builder: (context, _) => _body(t),
      ),
    );
  }

  Widget _body(WiTokens t) {
    final searching = _query.text.trim().isNotEmpty;
    final kinds = _kinds;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _query,
            autofocus: false,
            style: TextStyle(color: t.bone, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search your library…',
              hintStyle: TextStyle(color: t.ash, fontSize: 14),
              prefixIcon: Icon(Icons.search, color: t.ash, size: 20),
              suffixIcon: searching
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: Icon(Icons.close, color: t.ash, size: 18),
                      onPressed: () {
                        _debounceTimer?.cancel();
                        _query.clear();
                        setState(() => _results = const []);
                      },
                    )
                  : null,
              isDense: true,
              filled: true,
              fillColor: t.ink2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (kinds.length > 1)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final k in [
                    'All',
                    if (kinds.contains('Music')) 'Music',
                    if (kinds.contains('Movies')) 'Movies',
                    if (kinds.contains('Episodes')) 'Episodes',
                  ])
                    FilterChip(
                      label: Text(k,
                          style: TextStyle(
                              fontSize: 12,
                              color: _filter == k ? t.ink : t.boneDim)),
                      selected: _filter == k,
                      selectedColor: t.accent,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _filter = k),
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          child: searching ? _searchResults(t) : _tree(t),
        ),
      ],
    );
  }

  // ── Grouped tree (no query) ────────────────────────────────────────

  Widget _tree(WiTokens t) {
    final shown = [
      for (final item in _items)
        if (_filter == 'All' || _kindOfItem(item) == _filter) item,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final item in shown)
          switch (item) {
            HomeEntry() => _unitRow(t, item.entry),
            HomeAlbum() => _albumTile(t, item),
            HomeArtist() => _artistTile(t, item),
            HomeShow() => _showTile(t, item),
            HomeSeason() => const SizedBox.shrink(),
          },
      ],
    );
  }

  List<String> _albumKeys(HomeAlbum album) =>
      [for (final tr in album.tracks) _keyOf(tr)];

  List<String> _seasonKeys(HomeSeason season) =>
      [for (final e in season.episodes) _keyOf(e)];

  /// Leading tri-state checkbox for a group of unit [keys] — one tap
  /// selects the whole album/season/artist/show.
  Widget _groupCheckbox(WiTokens t, List<String> keys) => Checkbox(
        tristate: true,
        value: _groupValue(keys),
        activeColor: t.accent,
        onChanged: (_) => _toggleGroup(keys),
      );

  Widget _albumTile(WiTokens t, HomeAlbum album, {bool nested = false}) {
    final keys = _albumKeys(album);
    return ExpansionTile(
      key: PageStorageKey('album|${album.artist}|${album.album}'),
      leading: _groupCheckbox(t, keys),
      tilePadding: EdgeInsets.only(left: nested ? 28 : 12, right: 12),
      title: Text(
        album.year == null ? album.album : '${album.album} (${album.year})',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.bone, fontSize: 13.5),
      ),
      subtitle: Text(
        '${album.artist} · ${album.tracks.length} '
        '${album.tracks.length == 1 ? 'track' : 'tracks'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.ash, fontSize: 11),
      ),
      iconColor: t.boneDim,
      collapsedIconColor: t.ash,
      children: [
        for (final track in album.tracks) _unitRow(t, track, indent: true),
      ],
    );
  }

  Widget _artistTile(WiTokens t, HomeArtist artist) {
    final keys = [
      for (final album in artist.albums) ..._albumKeys(album),
    ];
    return ExpansionTile(
      key: PageStorageKey('artist|${artist.artist}'),
      leading: _groupCheckbox(t, keys),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(artist.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.bone, fontSize: 13.5)),
      subtitle: Text(
        '${artist.albums.length} albums · ${artist.trackCount} tracks',
        style: TextStyle(color: t.ash, fontSize: 11),
      ),
      iconColor: t.boneDim,
      collapsedIconColor: t.ash,
      children: [
        for (final album in artist.albums)
          _albumTile(t, album, nested: true),
      ],
    );
  }

  Widget _seasonTile(WiTokens t, HomeSeason season) {
    final keys = _seasonKeys(season);
    return ExpansionTile(
      key: PageStorageKey('season|${season.show}|${season.season}'),
      leading: _groupCheckbox(t, keys),
      tilePadding: const EdgeInsets.only(left: 28, right: 12),
      title: Text('Season ${season.season}',
          style: TextStyle(color: t.bone, fontSize: 13.5)),
      subtitle: Text(
        '${season.episodes.length} '
        '${season.episodes.length == 1 ? 'episode' : 'episodes'}',
        style: TextStyle(color: t.ash, fontSize: 11),
      ),
      iconColor: t.boneDim,
      collapsedIconColor: t.ash,
      children: [
        for (final ep in season.episodes) _unitRow(t, ep, indent: true),
      ],
    );
  }

  Widget _showTile(WiTokens t, HomeShow show) {
    final keys = [
      for (final season in show.seasons) ..._seasonKeys(season),
    ];
    // The TMDB match (via any episode) carries the canonical title.
    final meta = MetadataService.instance
        .metadataFor(show.seasons.first.episodes.first);
    return ExpansionTile(
      key: PageStorageKey('show|${show.show}'),
      leading: _groupCheckbox(t, keys),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(meta.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.bone, fontSize: 13.5)),
      subtitle: Text(
        '${show.seasons.length} '
        '${show.seasons.length == 1 ? 'season' : 'seasons'} · '
        '${show.episodeCount} episodes',
        style: TextStyle(color: t.ash, fontSize: 11),
      ),
      iconColor: t.boneDim,
      collapsedIconColor: t.ash,
      children: [
        if (show.seasons.length == 1)
          for (final ep in show.seasons.single.episodes)
            _unitRow(t, ep, indent: true)
        else
          for (final season in show.seasons) _seasonTile(t, season),
      ],
    );
  }

  // ── Search results (query non-empty) ───────────────────────────────

  Widget _searchResults(WiTokens t) {
    final rows = <Widget>[];
    final seen = <String>{};
    for (final r in _results) {
      switch (r) {
        case ShowResult(:final show):
          if (_filter != 'All' && _filter != 'Episodes') continue;
          if (!seen.add('show|${show.show}')) continue;
          rows.add(_showTile(t, show));
        case EntryResult(:final entry):
          final key = _keyOf(entry);
          final unit = _unitByKey[key];
          if (unit == null || !seen.add(key)) continue;
          final kind =
              parseMediaName(unit.rep.name).isAudio
                  ? 'Music'
                  : (r.isEpisode ? 'Episodes' : 'Movies');
          if (_filter != 'All' && _filter != kind) continue;
          rows.add(_unitRow(t, unit.rep));
      }
    }
    if (rows.isEmpty) {
      return Center(
        child: Text('Nothing matches.',
            style: TextStyle(color: t.boneDim, fontSize: 13)),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: rows,
    );
  }

  // ── Leaf rows ──────────────────────────────────────────────────────

  Widget _unitRow(WiTokens t, MediaEntry rep, {bool indent = false}) {
    final key = _keyOf(rep);
    final p = parseMediaName(rep.name);
    final meta = MetadataService.instance.metadataFor(rep);
    String title;
    String subtitle;
    if (p.isTrack) {
      title = episodeNameFromLabel(meta.episodeLabel) ??
          p.trackTitle ??
          p.title;
      subtitle = [
        if (p.artist != null) p.artist!,
        p.title,
      ].join(' · ');
    } else if (p.isAudio) {
      title = p.title;
      subtitle = '';
    } else if (p.isEpisode) {
      final marker = 'S${p.season.toString().padLeft(2, '0')}'
          'E${p.episode.toString().padLeft(2, '0')}';
      final name = episodeNameFromLabel(meta.episodeLabel);
      title = name == null ? marker : '$marker · $name';
      subtitle = indent ? '' : meta.title;
    } else {
      title = meta.title;
      subtitle = [if (meta.year != null) '${meta.year}'].join();
    }
    return CheckboxListTile(
      key: ValueKey('unit|$key'),
      value: _picked.contains(key),
      dense: true,
      activeColor: t.accent,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.only(left: indent ? 40 : 12, right: 12),
      onChanged: (on) => _toggle(key, on == true),
      secondary: Icon(
          p.isAudio ? Icons.music_note : Icons.movie_outlined,
          size: 16,
          color: t.ash),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.bone, fontSize: 13),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.ash, fontSize: 11),
            ),
    );
  }
}
