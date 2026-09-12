import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/embedded_client.dart';
import '../services/favourites.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/network_policy.dart';
import '../services/now_playing.dart';
import '../services/play_queue.dart';
import '../services/season_grouping.dart' show episodeNameFromLabel;
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/playlist_picker.dart' show playlistContentIcon;
import '../widgets/seek_slider.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart' show promptForText;

/// A playlist's own page: collage cover, Play all / Shuffle / Add
/// media, then the ordered rows — drag to reorder (the order IS the
/// play order), the row menu to remove, ⓘ/details for an item's own
/// page. Playlists hold ANY library title (2026-09-12): audio-only
/// playlists play inline through the same shared queue as the album
/// page; a playlist holding any video plays through the full-screen
/// [PlayerScreen] instead — each finished title rolls into the next via
/// the Up-next flow (marathon playback), audio rows included, since
/// PlayerScreen plays music too. Video rows show a poster thumb with
/// the watch bar and resume where they left off.
/// Renaming/deleting the playlist lives in the app-bar menu.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({
    super.key,
    required this.playlistId,
    this.playerFactory,
    this.sourceOverride,
    this.videoLauncherOverride,
  });

  final String playlistId;

  /// Test overrides, like the album page's.
  final AlbumAudioPlayer Function()? playerFactory;
  final ({String url, bool local})? Function(MediaEntry entry)?
      sourceOverride;

  /// Test override replacing the [PlayerScreen] push (widget tests have
  /// no native libmpv): receives the first entry and the play order.
  final void Function(MediaEntry first, List<MediaEntry> order)?
      videoLauncherOverride;

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

  /// Any video in the playlist flips the whole page to PlayerScreen
  /// playback (marathon mode) — the inline audio queue would play a
  /// movie sound-only.
  bool get _hasVideo =>
      _playlist?.entries.any((e) => !parseMediaName(e.name).isAudio) ??
      false;

  /// Playback source for [e]: the downloaded file when complete on
  /// disk, else the embedded client's stream URL (the test override
  /// wins).
  ({String url, bool local})? _sourceFor(MediaEntry e) {
    final override = widget.sourceOverride;
    if (override != null) return override(e);
    final local = DownloadManager.instance.localPathIfDone(e);
    if (local != null) return (url: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), e);
    return url == null ? null : (url: url, local: false);
  }

  /// The playlist entry after [current] in [order]; null at the end —
  /// PlayerScreen's Up-next flow turns this into marathon playback.
  static MediaEntry? _nextInOrder(
      List<MediaEntry> order, MediaEntry current) {
    final i = order.indexWhere(
        (e) => e.address == current.address && e.name == current.name);
    if (i < 0 || i + 1 >= order.length) return null;
    return order[i + 1];
  }

  /// A row tap / Play all on a playlist with video: open [first] in the
  /// full-screen PlayerScreen (resuming its saved position) with the
  /// rest of [order] chained behind it via Up-next. Same streaming
  /// gates as the detail page.
  Future<void> _playFrom(MediaEntry first, List<MediaEntry> order) async {
    final source = _sourceFor(first);
    if (source == null) {
      _snack('The built-in Autonomi client is not available.');
      return;
    }
    if (!source.local) {
      final gate = await streamingGateNow();
      if (gate == StreamingGate.block) {
        _snack("You're on mobile data — streaming is set to Wi-Fi only "
            '(Settings → Network)');
        return;
      }
      if (gate == StreamingGate.ask) {
        if (!mounted ||
            await confirmCellularStreaming(context) != true) {
          return;
        }
        CellularStreamingConsent.granted = true;
      }
    }
    var pausedForPlayback = false;
    if (!source.local && DownloadManager.instance.hasActive) {
      if (!mounted) return;
      pausedForPlayback = await maybePauseDownloadsForStreaming(context);
    }
    // The inline audio queue must not keep playing under the player.
    if (_queue.playing) unawaited(_queue.playOrPause());
    final state = await WatchStateStore.instance.newestFor([first]);
    final resumeFrom = state != null && state.resumable
        ? Duration(milliseconds: state.positionMs)
        : Duration.zero;
    final meta = MetadataService.instance.metadataFor(first);
    final bufferSizeMb = await AppSettings.bufferSizeMb();
    if (!mounted) return;
    final launcher = widget.videoLauncherOverride;
    if (launcher != null) {
      launcher(first, order);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: source.url,
          title: playerTitle(meta),
          entry: first,
          isLocal: source.local,
          resumeFrom: resumeFrom,
          nextFor: (e) => _nextInOrder(order, e),
          sourceFor: _sourceFor,
          bufferSizeMb: bufferSizeMb,
        ),
      ),
    );
    if (pausedForPlayback) {
      final resumed =
          await DownloadManager.instance.resumeAfterPlayback();
      if (resumed) _snack('Downloads resumed');
    }
    await _reload();
  }

  /// Row tap: audio-only playlists play inline; anything else goes
  /// through the PlayerScreen marathon starting at this row.
  Future<void> _playRow(MediaEntry entry) async {
    final playlist = _playlist;
    if (playlist == null) return;
    if (!_hasVideo) {
      await _queue.playTrack(entry);
      return;
    }
    await _playFrom(entry, playlist.entries);
  }

  /// [stampOrder] marks a deliberate reorder (drag) so My W@tch sync can
  /// merge play order newest-stamp-wins. Removal keeps the old stamp —
  /// the remaining rows' relative order is unchanged, and stamping there
  /// could clobber a newer reorder arriving from a linked device.
  Future<void> _persistOrder(List<MediaEntry> entries,
      {bool stampOrder = false}) async {
    final lists = await LibraryStore.load();
    final updated = [
      for (final l in lists)
        l.id == widget.playlistId
            ? l.copyWith(
                entries: entries,
                orderedAt: stampOrder
                    ? DateTime.now().millisecondsSinceEpoch
                    : null,
              )
            : l,
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

  /// Which chip a pool entry files under in the Add-media picker.
  static String _kindOf(ParsedName p) =>
      p.isAudio ? 'Music' : (p.isEpisode ? 'Episodes' : 'Movies');

  /// Every entry in the library's own lists (not channels, not
  /// playlists) — audio AND video — deduplicated by address: the
  /// Add-media picker's pool.
  static List<MediaEntry> _allMedia(List<MediaList> lists) {
    final seen = <String>{};
    final out = <MediaEntry>[];
    for (final l in lists) {
      if (l.isChannel || l.isPlaylist) continue;
      for (final e in l.entries) {
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
      for (final e in _allMedia(lists))
        if (!held.contains(e.address.toLowerCase())) e,
    ];
    if (!mounted) return;
    if (pool.isEmpty) {
      _snack('Everything in your library is already here.');
      return;
    }
    final kinds = {for (final e in pool) _kindOf(parseMediaName(e.name))};
    final picked = <int>{};
    var filter = 'All';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final t = WiTokens.of(context);
        return StatefulBuilder(builder: (context, setDialogState) {
          final shown = [
            for (final (i, e) in pool.indexed)
              if (filter == 'All' ||
                  _kindOf(parseMediaName(e.name)) == filter)
                i,
          ];
          return AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Add media',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: SizedBox(
              width: 420,
              height: 460,
              child: Column(
                children: [
                  // Type chips (only when the pool actually mixes
                  // types): Music / Movies / Episodes.
                  if (kinds.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
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
                                      color: filter == k
                                          ? t.ink
                                          : t.boneDim)),
                              selected: filter == k,
                              selectedColor: t.accent,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setDialogState(() => filter = k),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, row) {
                        final i = shown[row];
                        final e = pool[i];
                        final p = parseMediaName(e.name);
                        final subtitle = p.isAudio
                            ? [
                                if (p.artist != null) p.artist!,
                                if (p.isTrack) p.title,
                              ].join(' · ')
                            : p.isEpisode
                                ? [
                                    p.title,
                                    'S${p.season.toString().padLeft(2, '0')}'
                                        'E${p.episode.toString().padLeft(2, '0')}',
                                  ].join(' · ')
                                : [if (p.year != null) '${p.year}']
                                    .join();
                        return CheckboxListTile(
                          value: picked.contains(i),
                          dense: true,
                          activeColor: t.accent,
                          controlAffinity:
                              ListTileControlAffinity.leading,
                          onChanged: (on) => setDialogState(() {
                            on == true
                                ? picked.add(i)
                                : picked.remove(i);
                          }),
                          secondary: Icon(
                              p.isAudio
                                  ? Icons.music_note
                                  : Icons.movie_outlined,
                              size: 16,
                              color: t.ash),
                          title: Text(
                            p.trackTitle ?? p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: t.bone, fontSize: 13),
                          ),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: t.ash, fontSize: 11),
                                ),
                        );
                      },
                    ),
                  ),
                ],
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
      _snack(added == 1 ? '1 item added.' : '$added items added.');
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Content-derived icon — audio, video, or mixed.
                Icon(playlistContentIcon(playlist),
                    size: 12, color: t.ash),
                const SizedBox(width: 4),
                Text(
                  _hasVideo
                      ? 'Playlist · $count '
                          '${count == 1 ? 'item' : 'items'}'
                      : 'Playlist · $count '
                          '${count == 1 ? 'track' : 'tracks'}',
                  style: TextStyle(color: t.ash, fontSize: 11),
                ),
              ],
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
                              : () => unawaited(_hasVideo
                                  ? _playFrom(entries.first, entries)
                                  : _queue.playTrack(entries.first)),
                          icon: const Icon(Icons.play_arrow, size: 20),
                          label: const Text('Play all'),
                        ),
                        OutlinedButton.icon(
                          onPressed: entries.isEmpty
                              ? null
                              : () {
                                  if (_hasVideo) {
                                    // Shuffled marathon: one random
                                    // pass, chained through Up-next.
                                    final order = [...entries]
                                      ..shuffle(Random());
                                    unawaited(
                                        _playFrom(order.first, order));
                                    return;
                                  }
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
                          label: const Text('Add media'),
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
                    'This playlist is empty — Add media above, or use '
                    '"Add to playlist" on any track, movie, or episode.',
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
                    unawaited(_persistOrder(list, stampOrder: true));
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
              child: WiSeekSlider(
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

  /// 2:3 poster thumb for a video row, with a slim watch bar along its
  /// bottom edge when the title is partway watched.
  Widget _videoThumb(WiTokens t, MediaEntry entry, MediaMetadata meta) {
    final state = WatchStateStore.instance.cachedNewestFor([entry]);
    final showBar =
        state != null && state.resumable && state.progress > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 34,
        height: 51,
        child: Stack(
          fit: StackFit.expand,
          children: [
            entryPosterImage(meta, fit: BoxFit.cover) ??
                Container(
                  color: t.ink2,
                  child:
                      Icon(Icons.movie_outlined, size: 16, color: t.ash),
                ),
            if (showBar)
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 4,
                  child: LinearProgressIndicator(
                    value: state.progress,
                    backgroundColor: Colors.black45,
                    color: t.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _trackRow(WiTokens t, MediaEntry entry, int index) {
    final parsed = parseMediaName(entry.name);
    final isVideo = !parsed.isAudio;
    final meta = MetadataService.instance.metadataFor(entry);
    final title = episodeNameFromLabel(meta.episodeLabel) ??
        parsed.trackTitle ??
        (isVideo ? meta.title : parsed.title);
    // Audio rows read artist · album; an episode row reads its show,
    // a movie row its year.
    final subtitle = isVideo
        ? (parsed.isEpisode
            ? meta.title
            : [if (meta.year != null) '${meta.year}'].join())
        : [
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
      onTap: () => unawaited(_playRow(entry)),
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
            if (isVideo) ...[
              _videoThumb(t, entry, meta),
              const SizedBox(width: 10),
            ],
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
                    child: Text(isVideo ? 'Details' : 'Track details',
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
