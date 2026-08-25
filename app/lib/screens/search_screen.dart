import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../services/library_search.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/download_badge.dart';
import '../widgets/watch_progress.dart';
import 'detail_screen.dart';
import 'show_screen.dart';

/// Full-screen library search (docs/PLAN-home-search.md): an autofocused
/// query field in the app bar, live results-as-you-type over the
/// in-memory library, grouped Shows / Movies / Episodes. Local only —
/// this searches the user's lists, not TMDB.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.lists});

  /// The home screen's lists (disabled ones are skipped by the index).
  final List<MediaList> lists;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  /// Cosmetic typing debounce — the scan itself is in-memory and fast.
  static const _debounce = Duration(milliseconds: 150);

  /// Below this many typed characters the screen shows the hint instead
  /// of results (single letters match half the library).
  static const _minChars = 2;

  /// Results shown per group before the "Show all N" expander.
  static const _groupCap = 20;

  final _controller = TextEditingController();

  /// Escape must close the screen even while the query field is focused
  /// (which is almost always) — the field's own focus node sees the key
  /// before the field can swallow it, unlike an ancestor shortcut.
  late final _searchFocus = FocusNode(onKeyEvent: (node, event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  });

  Timer? _debounceTimer;
  late SearchIndex _index;
  List<SearchResult> _results = const [];
  String _query = '';
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _index = _buildIndex();
    // Cached TMDB matches land asynchronously (canonical titles, episode
    // names, artwork) — rebuild the index and rerun the query as they do.
    MetadataService.instance.addListener(_onMetadataChanged);
    _controller.addListener(_onQueryEdited);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    MetadataService.instance.removeListener(_onMetadataChanged);
    _controller.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  SearchIndex _buildIndex() => SearchIndex.build(
        widget.lists,
        episodeName: (e) => episodeNameFromLabel(
            MetadataService.instance.metadataFor(e).episodeLabel),
      );

  void _onMetadataChanged() {
    if (!mounted) return;
    _index = _buildIndex();
    _runQuery();
  }

  void _onQueryEdited() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _runQuery);
    // The clear button's visibility tracks the text immediately.
    setState(() {});
  }

  void _runQuery() {
    if (!mounted) return;
    final q = _controller.text.trim();
    setState(() {
      _query = q;
      _results = q.length < _minChars ? const [] : _index.query(q);
    });
  }

  Future<void> _openEntry(MediaEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
    );
  }

  Future<void> _openShow(HomeShow show) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ShowScreen(seasons: show.seasons)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: t.ink,
          elevation: 0,
          title: TextField(
            controller: _controller,
            focusNode: _searchFocus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: 16, color: t.bone),
            cursorColor: t.accent,
            decoration: InputDecoration(
              hintText: 'Search your library',
              hintStyle: TextStyle(fontSize: 16, color: t.ash),
              border: InputBorder.none,
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: Icon(Icons.close, color: t.boneDim),
                      onPressed: _controller.clear,
                    ),
            ),
          ),
        ),
        // Poster thumbs upgrade as TMDB matches land; badges/bars track
        // downloads and watch states live.
        body: ListenableBuilder(
          listenable: Listenable.merge(
              [DownloadManager.instance, WatchStateStore.instance]),
          builder: (context, _) => _body(t),
        ),
      ),
    );
  }

  Widget _body(WiTokens t) {
    if (_query.length < _minChars) {
      return _message(t, Icons.search,
          'Search your library — titles, years, S01E02');
    }
    if (_results.isEmpty) {
      return _message(t, Icons.search_off, 'No matches in your library');
    }
    final shows = <ShowResult>[];
    final movies = <EntryResult>[];
    final episodes = <EntryResult>[];
    for (final r in _results) {
      switch (r) {
        case ShowResult():
          shows.add(r);
        case EntryResult() when r.isEpisode:
          episodes.add(r);
        case EntryResult():
          movies.add(r);
      }
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ..._section(t, 'Shows', shows, _showTile),
        ..._section(t, 'Movies', movies, _movieTile),
        ..._section(t, 'Episodes', episodes, _episodeTile),
      ],
    );
  }

  Widget _message(WiTokens t, IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: t.ash),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.ash),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _section<T extends SearchResult>(WiTokens t, String title,
      List<T> items, Widget Function(WiTokens, T) tile) {
    if (items.isEmpty) return const [];
    final expanded = _expanded.contains(title);
    final shown = expanded ? items : items.take(_groupCap).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: t.bone,
          ),
        ),
      ),
      for (final r in shown) tile(t, r),
      if (!expanded && items.length > _groupCap)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: TextButton(
              onPressed: () => setState(() => _expanded.add(title)),
              child: Text(
                'Show all ${items.length}',
                style: TextStyle(fontSize: 12.5, color: t.accent),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _showTile(WiTokens t, ShowResult r) {
    final show = r.show;
    // Any episode's match carries the show title and show artwork.
    final meta = MetadataService.instance
        .metadataFor(show.seasons.first.episodes.first);
    final seasons = show.seasons.length;
    return ListTile(
      leading: _thumb(
        t,
        showPosterImage(meta, fit: BoxFit.cover),
        Icons.live_tv_outlined,
        badge: groupDownloadBadge(
            t, [for (final s in show.seasons) ...s.episodes]),
      ),
      title: Text(meta.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13.5, color: t.bone)),
      subtitle: Text(
        seasons == 1
            ? 'Season ${show.seasons.single.season} · '
                '${show.episodeCount} ep'
            : '$seasons seasons · ${show.episodeCount} ep',
        style: TextStyle(fontSize: 11.5, color: t.ash),
      ),
      onTap: () => _openShow(show),
    );
  }

  Widget _movieTile(WiTokens t, EntryResult r) {
    final entry = r.entry;
    final meta = MetadataService.instance.metadataFor(entry);
    return ListTile(
      leading: _thumb(
        t,
        posterImage(meta, fit: BoxFit.cover),
        Icons.movie_outlined,
        badge: entryDownloadBadge(t, entry),
        bar: entryWatchBar(t, entry),
      ),
      title: Text(
        meta.year != null ? '${meta.title} (${meta.year})' : meta.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.5, color: t.bone),
      ),
      trailing: _watchedCheck(t, entry),
      onTap: () => _openEntry(entry),
    );
  }

  Widget _episodeTile(WiTokens t, EntryResult r) {
    final entry = r.entry;
    final meta = MetadataService.instance.metadataFor(entry);
    return ListTile(
      leading: _thumb(
        t,
        stillImage(meta, fit: BoxFit.cover) ??
            entryPosterImage(meta, fit: BoxFit.cover),
        Icons.live_tv_outlined,
        badge: entryDownloadBadge(t, entry),
        bar: entryWatchBar(t, entry),
      ),
      // The match's title is the show name; episodeLabel is the bare
      // marker until TMDB supplies `S01E02 · Name`.
      title: Text(meta.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13.5, color: t.bone)),
      subtitle: Text(
        meta.episodeLabel ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: t.ash),
      ),
      trailing: _watchedCheck(t, entry),
      onTap: () => _openEntry(entry),
    );
  }

  /// Accent check for a fully watched movie/episode (the cards' watch
  /// bar covers only partial progress).
  Widget? _watchedCheck(WiTokens t, MediaEntry entry) {
    final state = WatchStateStore.instance.cachedStateFor(entry);
    if (state == null || !state.completed) return null;
    return Icon(Icons.check_circle_outline, size: 18, color: t.accent);
  }

  /// Small poster thumbnail with the cards' download badge and watch bar
  /// overlaid, falling back to a placeholder icon.
  Widget _thumb(WiTokens t, Widget? image, IconData placeholder,
      {Widget? badge, Widget? bar}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 44,
        height: 62,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image ??
                Container(
                  color: t.ink2,
                  child: Icon(placeholder, color: t.ash, size: 20),
                ),
            ?bar,
            ?badge,
          ],
        ),
      ),
    );
  }
}
