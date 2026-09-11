import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../services/favourites.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/now_playing.dart';
import '../services/play_queue.dart';
import '../services/season_grouping.dart' show episodeNameFromLabel;
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import 'detail_screen.dart';
import 'settings_screen.dart' show promptForText;

/// A playlist's own page: collage cover, Play all / Shuffle / Add
/// tracks, then the ordered track rows — drag to reorder (the order IS
/// the play order), swipe the row menu to remove, ⓘ for the track's
/// detail page. Playback runs inline through the same shared queue as
/// the album page; mixes and standalone audio are first-class rows
/// here. Renaming/deleting the playlist lives in the app-bar menu.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({
    super.key,
    required this.playlistId,
    this.playerFactory,
    this.sourceOverride,
  });

  final String playlistId;

  /// Test overrides, like the album page's.
  final AlbumAudioPlayer Function()? playerFactory;
  final ({String url, bool local})? Function(MediaEntry entry)?
      sourceOverride;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  MediaList? _playlist;
  bool _loaded = false;

  late final PlayQueueController _queue = PlayQueueController(
    tracks: () => _playlist?.entries ?? const [],
    trackInfo: _trackInfo,
    playerFactory: widget.playerFactory,
    sourceOverride: widget.sourceOverride,
    confirmCellular: () async =>
        mounted && await confirmCellularStreaming(context) == true,
    pauseDownloadsPrompt: () async =>
        mounted && await maybePauseDownloadsForStreaming(context),
    onMessage: _snack,
  );

  @override
  void initState() {
    super.initState();
    unawaited(FavouritesStore.instance.ensureLoaded());
    _queue.addListener(_onQueue);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueue);
    _queue.dispose();
    super.dispose();
  }

  void _onQueue() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    MediaList? found;
    for (final l in lists) {
      if (l.id == widget.playlistId) found = l;
    }
    if (!mounted) return;
    setState(() {
      _playlist = found;
      _loaded = true;
    });
  }

  NowPlayingTrack _trackInfo(MediaEntry entry) {
    final meta = MetadataService.instance.metadataFor(entry);
    final parsed = parseMediaName(entry.name);
    return NowPlayingTrack(
      title: episodeNameFromLabel(meta.episodeLabel) ??
          parsed.trackTitle ??
          parsed.title,
      artist: meta.trackArtist ?? meta.artist ?? parsed.artist,
      album: _playlist?.title,
      artworkPath: meta.episodePosterFilePath ?? meta.posterFilePath,
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _persistOrder(List<MediaEntry> entries) async {
    final lists = await LibraryStore.load();
    final updated = [
      for (final l in lists)
        l.id == widget.playlistId ? l.copyWith(entries: entries) : l,
    ];
    await LibraryStore.save(updated);
    await _reload();
  }

  Future<void> _removeTrack(MediaEntry entry) async {
    final playlist = _playlist;
    if (playlist == null) return;
    await _persistOrder([
      for (final e in playlist.entries)
        if (!(e.address == entry.address && e.name == entry.name)) e,
    ]);
  }

  Future<void> _rename() async {
    final playlist = _playlist;
    if (playlist == null) return;
    final title = await promptForText(context,
        title: 'Rename playlist',
        hint: 'Playlist name',
        initial: playlist.title);
    if (title == null || title.trim().isEmpty) return;
    final lists = await LibraryStore.load();
    await LibraryStore.save([
      for (final l in lists)
        l.id == playlist.id ? l.copyWith(title: title.trim()) : l,
    ]);
    await _reload();
  }

  Future<void> _delete() async {
    final playlist = _playlist;
    if (playlist == null) return;
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Delete "${playlist.title}"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The playlist is removed. The tracks themselves stay in your '
          'library.',
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
    if (confirmed != true || !mounted) return;
    final lists = await LibraryStore.load();
    await LibraryStore.save(
        [for (final l in lists) if (l.id != playlist.id) l]);
    if (mounted) Navigator.of(context).pop();
  }

  /// Every audio entry in the library's own lists (not channels, not
  /// playlists), deduplicated by address — the Add-tracks picker's pool.
  static List<MediaEntry> _allAudio(List<MediaList> lists) {
    final seen = <String>{};
    final out = <MediaEntry>[];
    for (final l in lists) {
      if (l.isChannel || l.isPlaylist) continue;
      for (final e in l.entries) {
        if (!parseMediaName(e.name).isAudio) continue;
        if (seen.add(e.address.toLowerCase())) out.add(e);
      }
    }
    out.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<void> _addTracks() async {
    final playlist = _playlist;
    if (playlist == null) return;
    final lists = await LibraryStore.load();
    final held = {
      for (final e in playlist.entries) e.address.toLowerCase(),
    };
    final pool = [
      for (final e in _allAudio(lists))
        if (!held.contains(e.address.toLowerCase())) e,
    ];
    if (!mounted) return;
    if (pool.isEmpty) {
      _snack('Every audio track in your library is already here.');
      return;
    }
    final picked = <int>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final t = WiTokens.of(context);
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Add tracks',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: SizedBox(
              width: 420,
              height: 420,
              child: ListView.builder(
                itemCount: pool.length,
                itemBuilder: (context, i) {
                  final e = pool[i];
                  final p = parseMediaName(e.name);
                  return CheckboxListTile(
                    value: picked.contains(i),
                    dense: true,
                    activeColor: t.accent,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (on) => setDialogState(() {
                      on == true ? picked.add(i) : picked.remove(i);
                    }),
                    title: Text(
                      p.trackTitle ?? p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.bone, fontSize: 13),
                    ),
                    subtitle: Text(
                      [
                        if (p.artist != null) p.artist!,
                        if (p.isTrack) p.title,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.ash, fontSize: 11),
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
              FilledButton(
                onPressed: picked.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: const Text('Add'),
              ),
            ],
          );
        });
      },
    );
    if (confirmed != true || !mounted) return;
    final added = await addTracksToPlaylist(
        playlist.id, [for (final i in picked.toList()..sort()) pool[i]]);
    await _reload();
    if (added > 0) {
      _snack(added == 1 ? '1 track added.' : '$added tracks added.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final playlist = _playlist;
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(backgroundColor: t.ink, elevation: 0),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: t.ink, elevation: 0),
        body: Center(
          child: Text('This playlist no longer exists.',
              style: TextStyle(fontSize: 13, color: t.boneDim)),
        ),
      );
    }
    final count = playlist.entries.length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(playlist.title,
                style: TextStyle(color: t.bone, fontSize: 18),
                overflow: TextOverflow.ellipsis),
            Text(
              'Playlist · $count ${count == 1 ? 'track' : 'tracks'}',
              style: TextStyle(color: t.ash, fontSize: 11),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Playlist menu',
            icon: Icon(Icons.more_vert, color: t.boneDim),
            color: t.ink2,
            onSelected: (v) => switch (v) {
              'rename' => unawaited(_rename()),
              'delete' => unawaited(_delete()),
              _ => null,
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: 'rename',
                  child: Text('Rename playlist',
                      style: TextStyle(color: t.bone, fontSize: 13))),
              PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete playlist',
                      style: TextStyle(color: t.rust, fontSize: 13))),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          MetadataService.instance,
          DownloadManager.instance,
          WatchStateStore.instance,
          FavouritesStore.instance,
        ]),
        builder: (context, _) => _body(t, playlist),
      ),
    );
  }

  Widget _body(WiTokens t, MediaList playlist) {
    final entries = playlist.entries;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _collage(t, entries),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: entries.isEmpty
                              ? null
                              : () => unawaited(
                                  _queue.playTrack(entries.first)),
                          icon: const Icon(Icons.play_arrow, size: 20),
                          label: const Text('Play all'),
                        ),
                        OutlinedButton.icon(
                          onPressed: entries.isEmpty
                              ? null
                              : () {
                                  if (!_queue.shuffle) {
                                    _queue.toggleShuffle();
                                  }
                                  unawaited(_queue.playTrack(entries[
                                      DateTime.now().millisecond %
                                          entries.length]));
                                },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: t.bone,
                            side: BorderSide(color: t.ash),
                          ),
                          icon: const Icon(Icons.shuffle, size: 18),
                          label: const Text('Shuffle'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_addTracks()),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: t.bone,
                            side: BorderSide(color: t.ash),
                          ),
                          icon: const Icon(Icons.playlist_add, size: 18),
                          label: const Text('Add tracks'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Drag rows to reorder — the order here is the '
                      'play order.',
                      style: TextStyle(fontSize: 11.5, color: t.ash),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_queue.current != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _nowPlaying(t),
          ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'This playlist is empty — Add tracks above, or use '
                    '"Add to playlist" on any track.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: t.boneDim),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final list = [...entries];
                    final moved = list.removeAt(oldIndex);
                    list.insert(newIndex, moved);
                    unawaited(_persistOrder(list));
                  },
                  itemBuilder: (context, i) =>
                      _trackRow(t, entries[i], i),
                ),
        ),
      ],
    );
  }

  /// 2×2 collage of the first tracks' artwork (music-note fallback) —
  /// the playlist's face.
  Widget _collage(WiTokens t, List<MediaEntry> entries) {
    Widget cell(int i) {
      final image = i < entries.length
          ? entryPosterImage(
              MetadataService.instance.metadataFor(entries[i]),
              fit: BoxFit.cover)
          : null;
      return image ??
          Container(
            color: t.ink2,
            child: Icon(Icons.music_note, color: t.ash, size: 20),
          );
    }

    const size = 112.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 1,
          crossAxisSpacing: 1,
          children: [for (var i = 0; i < 4; i++) cell(i)],
        ),
      ),
    );
  }

  static String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Compact transport for the playing track (the album page's, minus
  /// the cover glow — the collage stays put).
  Widget _nowPlaying(WiTokens t) {
    final current = _queue.current!;
    final info = _trackInfo(current);
    final fav = FavouritesStore.instance.isFavourite(current.address);
    final position = _queue.position;
    final duration = _queue.duration;
    final maxMs = duration.inMilliseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [info.title, if (info.artist != null) info.artist!].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13.5, fontWeight: FontWeight.w600, color: t.bone),
        ),
        Row(
          children: [
            Text(_clock(position),
                style: TextStyle(
                    fontSize: 11,
                    color: t.ash,
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback)),
            Expanded(
              child: Slider(
                value: maxMs == 0
                    ? 0
                    : position.inMilliseconds.clamp(0, maxMs).toDouble(),
                max: maxMs == 0 ? 1 : maxMs.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.ink2,
                onChanged: maxMs == 0
                    ? null
                    : (v) => unawaited(
                        _queue.seek(Duration(milliseconds: v.round()))),
              ),
            ),
            Text(_clock(duration),
                style: TextStyle(
                    fontSize: 11,
                    color: t.ash,
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback)),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: _queue.shuffle ? 'Shuffle off' : 'Shuffle',
              onPressed: _queue.toggleShuffle,
              icon: Icon(Icons.shuffle,
                  size: 22, color: _queue.shuffle ? t.accent : t.ash),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Previous track',
              onPressed: _queue.skipPrevious,
              icon: Icon(Icons.skip_previous, size: 28, color: t.bone),
            ),
            IconButton.filled(
              tooltip: _queue.playing ? 'Pause' : 'Play',
              style: IconButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: t.ink,
              ),
              onPressed: () => unawaited(_queue.playOrPause()),
              icon: Icon(_queue.playing ? Icons.pause : Icons.play_arrow,
                  size: 28),
            ),
            IconButton(
              tooltip: 'Next track',
              onPressed: _queue.skipNext,
              icon: Icon(Icons.skip_next, size: 28, color: t.bone),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip:
                  fav ? 'Remove from favourites' : 'Add to favourites',
              onPressed: () => unawaited(
                  FavouritesStore.instance.toggle(current.address)),
              icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                  size: 22, color: fav ? t.accent : t.ash),
            ),
          ],
        ),
      ],
    );
  }

  Widget _trackRow(WiTokens t, MediaEntry entry, int index) {
    final parsed = parseMediaName(entry.name);
    final meta = MetadataService.instance.metadataFor(entry);
    final title = episodeNameFromLabel(meta.episodeLabel) ??
        parsed.trackTitle ??
        parsed.title;
    final subtitle = [
      if (meta.trackArtist != null)
        meta.trackArtist!
      else if (parsed.artist != null)
        parsed.artist!,
      if (parsed.isTrack) parsed.title,
    ].join(' · ');
    final downloaded =
        DownloadManager.instance.taskFor(entry.address)?.status ==
            DownloadStatus.done;
    final isCurrent = _queue.current?.address == entry.address &&
        _queue.current?.name == entry.name;
    return InkWell(
      key: ValueKey('${entry.address}|${entry.name}'),
      onTap: () => unawaited(_queue.playTrack(entry)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Icon(Icons.drag_indicator, size: 18, color: t.ash),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 28,
              child: isCurrent
                  ? Icon(Icons.graphic_eq, size: 16, color: t.accent)
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontFamily: wiMonoFamily,
                        fontFamilyFallback: wiMonoFallback,
                        fontSize: 12,
                        color: t.accent,
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: isCurrent ? t.accent : t.bone,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: t.ash),
                    ),
                ],
              ),
            ),
            if (downloaded) ...[
              const SizedBox(width: 8),
              Icon(Icons.download_done, size: 16, color: t.ash),
            ],
            PopupMenuButton<String>(
              tooltip: 'Track menu',
              icon: Icon(Icons.more_vert, size: 16, color: t.ash),
              color: t.ink2,
              onSelected: (v) => switch (v) {
                'remove' => unawaited(_removeTrack(entry)),
                'details' => unawaited(() async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DetailScreen(entry: entry)));
                    await _reload();
                  }()),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                    value: 'details',
                    child: Text('Track details',
                        style: TextStyle(color: t.bone, fontSize: 13))),
                PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove from playlist',
                        style: TextStyle(color: t.rust, fontSize: 13))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
