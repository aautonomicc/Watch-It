import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../services/library_arrangement.dart';
import '../services/library_store.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import '../widgets/channel_info_card.dart';
import '../widgets/library_drawer.dart';
import '../widgets/poster_cards.dart';
import 'detail_screen.dart';
import 'show_screen.dart';

/// A list's own page: every entry as a poster grid (shows folded into one
/// card, like the wall) behind a row of genre chips built from the TMDB
/// matches. Chips are multi-select — Science Fiction + Comedy narrows to
/// entries carrying both.
class ListHomeScreen extends StatefulWidget {
  const ListHomeScreen({super.key, required this.list});

  final MediaList list;

  @override
  State<ListHomeScreen> createState() => _ListHomeScreenState();
}

class _ListHomeScreenState extends State<ListHomeScreen> {
  late MediaList _list = widget.list;

  /// Selected genre chips; empty means All.
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    // Grid cards badge their download state — have the queue loaded.
    unawaited(DownloadManager.instance.ensureLoaded());
  }

  /// Re-derive the list from the store (entries may change while a
  /// detail/show page or the Media Lists page is open on top). A deleted
  /// list keeps showing its last snapshot — back leads out anyway.
  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    MediaList? updated;
    for (final l in lists) {
      if (l.id == _list.id) updated = l;
    }
    if (mounted && updated != null) setState(() => _list = updated!);
  }

  Future<void> _openEntry(MediaEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
    );
    await _reload();
  }

  Future<void> _openShow(HomeShow group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ShowScreen(seasons: group.seasons)),
    );
    await _reload();
  }

  /// The metadata that carries an item's genres: the entry's own match,
  /// or — for a folded show — any episode's match, whose category IS the
  /// show's genre list.
  List<String> _genresOf(HomeItem item) {
    final entry = switch (item) {
      HomeEntry(:final entry) => entry,
      HomeShow(:final seasons) => seasons.first.episodes.first,
      HomeSeason(:final episodes) => episodes.first,
    };
    return genreNames(MetadataService.instance.metadataFor(entry).category);
  }

  bool _matches(List<String> genres, Set<String> selected) {
    for (final s in selected) {
      final ok =
          s == kUncategorised ? genres.isEmpty : genres.contains(s);
      if (!ok) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final count = _list.entries.length;
    return Scaffold(
      drawer: WiLibraryDrawer(currentListId: _list.id),
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        // With a drawer mounted Flutter would put the hamburger here and
        // drop the back affordance entirely — keep back on the left, the
        // drawer opens from the menu action on the right.
        leading: BackButton(color: t.boneDim),
        // Channel pages carry the full-width info card below, which owns
        // the entry count — the app bar stays plain there.
        title: _list.isChannel
            ? Text(_list.title,
                style: TextStyle(color: t.bone, fontSize: 18))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_list.title,
                      style: TextStyle(color: t.bone, fontSize: 18)),
                  Text(
                    '$count ${count == 1 ? 'entry' : 'entries'}',
                    style: TextStyle(color: t.ash, fontSize: 11),
                  ),
                ],
              ),
        actions: [
          // The pushed route puts a back arrow in `leading`, so the
          // drawer needs its own handle here.
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Browse lists',
              icon: Icon(Icons.menu, color: t.boneDim),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [MetadataService.instance, DownloadManager.instance]),
        builder: (context, _) => _body(t),
      ),
    );
  }

  Widget _body(WiTokens t) {
    // The channel's face — profile card above the grid (a grid cell is
    // poster-shaped; a profile crammed into one would fight the grid).
    final infoCard = _list.isChannel
        ? ChannelInfoCard(list: _list, onEdited: _reload)
        : null;
    if (_list.entries.isEmpty) {
      final empty = Center(
        child: Text(
          'This list is empty.',
          style: TextStyle(fontSize: 13, color: t.boneDim),
        ),
      );
      return infoCard == null
          ? empty
          : Column(children: [infoCard, Expanded(child: empty)]);
    }
    final items = groupShows(_list.entries);
    // Channel lists carry no category tags by design — manifests are
    // published without them, and a subscriber's own TMDB matches must
    // not sneak genre chips back onto the channel's page.
    final chips = <String>[];
    if (!_list.isChannel) {
      final genres = <String>{};
      var hasUncategorised = false;
      for (final item in items) {
        final g = _genresOf(item);
        if (g.isEmpty) {
          hasUncategorised = true;
        } else {
          genres.addAll(g);
        }
      }
      chips.addAll([
        ...genres.toList()..sort(),
        // Only worth a chip when it narrows anything: a list where
        // nothing is categorised would show a lone Uncategorised chip
        // that filters nothing.
        if (hasUncategorised && genres.isNotEmpty) kUncategorised,
      ]);
    }
    // Ignore stale selections (a chip can vanish when a better TMDB
    // match lands) without mutating state during build.
    final active = {
      for (final s in _selected)
        if (chips.contains(s)) s,
    };
    final filtered = [
      for (final item in items)
        if (_matches(_genresOf(item), active)) item,
    ];
    return Column(
      children: [
        ?infoCard,
        if (chips.isNotEmpty) _chipRow(t, chips, active),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'Nothing here matches the selected genres.',
                    style: TextStyle(fontSize: 13, color: t.boneDim),
                  ),
                )
              : _grid(t, filtered),
        ),
      ],
    );
  }

  Widget _chipRow(WiTokens t, List<String> chips, Set<String> active) {
    Widget chip({
      required String label,
      required bool selected,
      required ValueChanged<bool> onSelected,
    }) {
      return FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        showCheckmark: false,
        backgroundColor: t.ink2,
        selectedColor: t.accent,
        side: BorderSide(color: selected ? t.accent : t.line),
        labelStyle: TextStyle(
          fontSize: 12,
          color: selected ? t.ink : t.boneDim,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: chips.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => i == 0
            ? chip(
                label: 'All',
                selected: active.isEmpty,
                onSelected: (_) => setState(_selected.clear),
              )
            : chip(
                label: chips[i - 1],
                selected: active.contains(chips[i - 1]),
                onSelected: (on) => setState(() {
                  _selected
                    ..clear()
                    ..addAll(active);
                  on
                      ? _selected.add(chips[i - 1])
                      : _selected.remove(chips[i - 1]);
                }),
              ),
      ),
    );
  }

  Widget _grid(WiTokens t, List<HomeItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisExtent: 236,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => switch (items[i]) {
        HomeEntry() && final item => PosterCard(
            entry: item.entry,
            versionCount: item.allVersions.length,
            tokens: t,
            onTap: () => _openEntry(item.entry),
          ),
        HomeShow() && final group => ShowCard(
            group: group,
            tokens: t,
            onTap: () => _openShow(group),
          ),
        // groupShows never yields bare seasons.
        HomeSeason() => const SizedBox.shrink(),
      },
    );
  }
}
