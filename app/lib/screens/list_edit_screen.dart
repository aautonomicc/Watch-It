import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;

/// Edit one media list: rename, delete, and curate entries in a tree —
/// episodes group under their show, then season, and multiple uploads of
/// one title (a 480p and a 1080p copy) under a single version tile
/// (movies and other singles stay top-level rows). Every item, season,
/// show, and version group offers Remove, Move-to-another-list, and
/// Copy-to-another-list (an existing list or a fresh one). Media is
/// added on the Media page ("Add to library"), which can also create
/// lists — this screen only curates what an import put there.
class ListEditScreen extends StatefulWidget {
  const ListEditScreen({super.key, required this.listId});

  final String listId;

  @override
  State<ListEditScreen> createState() => _ListEditScreenState();
}

class _ListEditScreenState extends State<ListEditScreen> {
  List<MediaList>? _lists;

  MediaList? get _list {
    final lists = _lists;
    if (lists == null) return null;
    for (final l in lists) {
      if (l.id == widget.listId) return l;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    LibraryStore.load().then((lists) {
      if (mounted) setState(() => _lists = lists);
    });
  }

  Future<void> _update(MediaList updated) async {
    final lists = List<MediaList>.of(_lists ?? []);
    final i = lists.indexWhere((l) => l.id == updated.id);
    if (i < 0) return;
    lists[i] = updated;
    await LibraryStore.save(lists);
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _rename() async {
    final list = _list;
    if (list == null) return;
    final title = await promptForText(
      context,
      title: 'Rename list',
      hint: 'List title',
      initial: list.title,
    );
    if (title == null || title.trim().isEmpty) return;
    await _update(list.copyWith(title: title.trim()));
  }

  Future<void> _deleteList() async {
    final list = _list;
    if (list == null) return;
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Delete "${list.title}"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The list and its ${list.entries.length} entries will be removed. '
          'Content on Autonomi is unaffected.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final lists = List<MediaList>.of(_lists ?? [])
      ..removeWhere((l) => l.id == list.id);
    await LibraryStore.save(lists);
    if (mounted) Navigator.of(context).pop();
  }

  static String _norm(String address) =>
      address.toLowerCase().replaceFirst('0x', '');

  /// Remove [entries] from this list. A single item goes straight away
  /// (like the old per-row ✕); a season or show removal asks first.
  Future<void> _removeEntries(List<MediaEntry> entries, String what) async {
    final list = _list;
    if (list == null) return;
    if (entries.length > 1) {
      final t = WiTokens.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Remove $what?',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Text(
            '${entries.length} entries leave "${list.title}". Content on '
            'Autonomi is unaffected.',
            style: TextStyle(color: t.boneDim, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Remove', style: TextStyle(color: t.rust)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final addrs = {for (final e in entries) _norm(e.address)};
    await _update(list.copyWith(entries: [
      for (final e in list.entries)
        if (!addrs.contains(_norm(e.address))) e,
    ]));
  }

  /// Move or copy [entries] into a picked target: any other non-channel
  /// list, or a freshly created one. A copy leaves this list untouched
  /// (for building custom playlists); a move removes the entries here.
  /// Duplicates already in the target are dropped, not doubled.
  Future<void> _transferEntries(List<MediaEntry> entries, String what,
      {required bool copy}) async {
    final list = _list;
    final lists = _lists;
    if (list == null || lists == null) return;
    final title = await _pickTransferTarget(what, copy: copy);
    final trimmed = title?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;

    final updated = List<MediaList>.of(lists);
    final srcIndex = updated.indexWhere((l) => l.id == list.id);
    if (srcIndex < 0) return;
    if (!copy) {
      final addrs = {for (final e in entries) _norm(e.address)};
      updated[srcIndex] = list.copyWith(entries: [
        for (final e in list.entries)
          if (!addrs.contains(_norm(e.address))) e,
      ]);
    }
    // A typed name matching an existing list merges into it — same rule
    // as the import flow's "Create new list" pseudo-rows.
    final targetIndex = updated.indexWhere((l) =>
        l.id != list.id &&
        !l.isChannel &&
        l.title.toLowerCase() == trimmed.toLowerCase());
    var duplicates = 0;
    String targetTitle;
    if (targetIndex >= 0) {
      final target = updated[targetIndex];
      targetTitle = target.title;
      final have = {for (final e in target.entries) _norm(e.address)};
      final fresh =
          [for (final e in entries) if (have.add(_norm(e.address))) e];
      duplicates = entries.length - fresh.length;
      updated[targetIndex] =
          target.copyWith(entries: [...target.entries, ...fresh]);
    } else {
      targetTitle = trimmed;
      updated.add(MediaList(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        title: trimmed,
        entries: entries,
      ));
    }
    await LibraryStore.save(updated);
    if (!mounted) return;
    setState(() => _lists = updated);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${copy ? 'Copied' : 'Moved'} ${entries.length} '
          '${entries.length == 1 ? 'entry' : 'entries'} to "$targetTitle"'
          '${duplicates > 0 ? ' ($duplicates already there)' : ''}'),
    ));
  }

  /// Target picker for a move or copy: the other non-channel lists plus
  /// "Create new list". Returns the chosen list title, or null on cancel.
  Future<String?> _pickTransferTarget(String what,
      {required bool copy}) async {
    final t = WiTokens.of(context);
    final others = [
      for (final l in _lists ?? <MediaList>[])
        if (l.id != widget.listId && !l.isChannel) l,
    ];
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('${copy ? 'Copy' : 'Move'} $what to…',
            style: TextStyle(color: t.bone, fontSize: 16)),
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in others)
                      ListTile(
                        dense: true,
                        title: Text(l.title,
                            style:
                                TextStyle(color: t.bone, fontSize: 14)),
                        subtitle: Text(
                            '${l.entries.length} '
                            '${l.entries.length == 1 ? 'entry' : 'entries'}',
                            style:
                                TextStyle(color: t.ash, fontSize: 11.5)),
                        onTap: () => Navigator.of(context).pop(l.title),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      final title = await promptForText(
                        context,
                        title: 'New media list',
                        hint: 'List title',
                      );
                      final trimmed = title?.trim();
                      if (trimmed == null || trimmed.isEmpty) return;
                      if (context.mounted) {
                        Navigator.of(context).pop(trimmed);
                      }
                    },
                    child: Text('Create new list',
                        style: TextStyle(color: t.bone)),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
        ],
      ),
    );
  }

  /// The Remove / Move / Copy menu shared by item, season, show, and
  /// version-group rows.
  Widget _entryMenu(WiTokens t, List<MediaEntry> entries, String what) {
    return PopupMenuButton<String>(
      tooltip: 'Options',
      icon: Icon(Icons.more_vert, size: 20, color: t.ash),
      color: t.ink2,
      onSelected: (v) => switch (v) {
        'move' => _transferEntries(entries, what, copy: false),
        'copy' => _transferEntries(entries, what, copy: true),
        'remove' => _removeEntries(entries, what),
        _ => null,
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'move',
          child: Text('Move to another list…',
              style: TextStyle(color: t.bone, fontSize: 14)),
        ),
        PopupMenuItem(
          value: 'copy',
          child: Text('Copy to another list…',
              style: TextStyle(color: t.bone, fontSize: 14)),
        ),
        PopupMenuItem(
          value: 'remove',
          child: Text('Remove from list',
              style: TextStyle(color: t.rust, fontSize: 14)),
        ),
      ],
    );
  }

  Widget _entryRow(WiTokens t, MediaEntry e, {double indent = 16}) {
    final info = formatInfoLine(e);
    return ListTile(
      contentPadding: EdgeInsets.only(left: indent, right: 4),
      title: Text(e.name, style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: info == null
          ? null
          : Text(info, style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(t, [e], '"${e.name}"'),
    );
  }

  /// Multiple uploads of one title (same parsed lookup key — e.g. a 480p
  /// and a 1080p copy) fold under a single expandable tile, mirroring the
  /// show → season tree: cleaner than N near-identical rows, and the
  /// group menu curates all versions at once.
  Widget _versionsTile(WiTokens t, HomeEntry item) {
    final versions = item.allVersions;
    final parsed = parseMediaName(item.entry.name);
    final title = parsed.title.isEmpty ? item.entry.name : parsed.title;
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 8, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text(title,
          style: TextStyle(
              color: t.bone, fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text('${versions.length} versions',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(
          t, versions, 'all ${versions.length} versions of "$title"'),
      children: [for (final e in versions) _entryRow(t, e, indent: 40)],
    );
  }

  /// An episode with several uploads (quality tiers) folds under its own
  /// nested tile inside the season, mirroring [_versionsTile] for
  /// movies; single-upload episodes stay plain rows.
  Widget _episodeRow(WiTokens t, HomeSeason season, MediaEntry e) {
    final versions = season.versionsOf(e);
    if (versions.length < 2) return _entryRow(t, e, indent: 56);
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 40, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text(e.name, style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: Text('${versions.length} versions',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(
          t, versions, 'all ${versions.length} versions of "${e.name}"'),
      children: [for (final v in versions) _entryRow(t, v, indent: 72)],
    );
  }

  Widget _seasonTile(WiTokens t, HomeSeason season) {
    final n = season.episodes.length;
    // The group menu curates every file, hidden tier uploads included —
    // a move must never strand an episode's other versions behind.
    final files = [
      for (final e in season.episodes) ...season.versionsOf(e),
    ];
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 24, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text('Season ${season.season}',
          style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: Text('$n ${n == 1 ? 'episode' : 'episodes'}',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(t, files,
          'season ${season.season} of "${season.show}"'),
      children: [
        for (final e in season.episodes) _episodeRow(t, season, e),
      ],
    );
  }

  /// An album's tracks fold under a single expandable tile, like a
  /// season's episodes; the group menu curates the whole album at once.
  /// Nested under an artist tile the album indents like a season.
  Widget _albumTile(WiTokens t, HomeAlbum group, {bool nested = false}) {
    final n = group.tracks.length;
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.only(left: nested ? 24 : 8, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text(group.album,
          style: TextStyle(
              color: t.bone, fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text('${group.artist} · $n ${n == 1 ? 'track' : 'tracks'}',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(t, group.tracks, '"${group.album}"'),
      children: [
        for (final e in group.tracks)
          _entryRow(t, e, indent: nested ? 56 : 40),
      ],
    );
  }

  /// An artist's albums fold under one expandable tile, mirroring the
  /// show → season tree; the group menu curates every track at once.
  Widget _artistTile(WiTokens t, HomeArtist group) {
    final all = [for (final a in group.albums) ...a.tracks];
    final n = group.albums.length;
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 8, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text(group.artist,
          style: TextStyle(
              color: t.bone, fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
          '$n albums · ${all.length} ${all.length == 1 ? 'track' : 'tracks'}',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(t, all, '"${group.artist}"'),
      children: [
        for (final a in group.albums) _albumTile(t, a, nested: true),
      ],
    );
  }

  Widget _showTile(WiTokens t, HomeShow group) {
    final seasons = group.seasons.length;
    final episodes = group.episodeCount;
    // Every file, tier uploads included (see _seasonTile).
    final all = [
      for (final s in group.seasons)
        for (final e in s.episodes) ...s.versionsOf(e),
    ];
    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      iconColor: t.ash,
      collapsedIconColor: t.ash,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.only(left: 8, right: 4),
      childrenPadding: EdgeInsets.zero,
      title: Text(group.show,
          style: TextStyle(
              color: t.bone, fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
          '$seasons ${seasons == 1 ? 'season' : 'seasons'} · '
          '$episodes ${episodes == 1 ? 'episode' : 'episodes'}',
          style: TextStyle(color: t.ash, fontSize: 12)),
      trailing: _entryMenu(t, all, '"${group.show}"'),
      children: [for (final s in group.seasons) _seasonTile(t, s)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final list = _list;
    // Episodes fold by show, then season — the same grouping as the
    // home wall, so curating mirrors what browsing shows.
    final items = list == null ? const <HomeItem>[] : groupShows(list.entries);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(list?.title ?? '',
            style: TextStyle(color: t.bone, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Rename list',
            icon: Icon(Icons.edit_outlined, color: t.boneDim),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: 'Delete list',
            icon: Icon(Icons.delete_outline, color: t.rust),
            onPressed: _deleteList,
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.entries.isEmpty
              ? Center(
                  child: Text(
                    'No entries yet.\nUse "Add to library" on the Media '
                    'page\nand pick this list.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: t.ash),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final item in items)
                      switch (item) {
                        HomeShow() && final group => _showTile(t, group),
                        HomeAlbum() && final album => _albumTile(t, album),
                        HomeArtist() && final artist =>
                          _artistTile(t, artist),
                        HomeEntry() && final single =>
                          single.allVersions.length > 1
                              ? _versionsTile(t, single)
                              : _entryRow(t, single.entry),
                        // groupShows never yields bare seasons.
                        HomeSeason() => const SizedBox.shrink(),
                      },
                  ],
                ),
    );
  }
}
