import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/favourites.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/now_playing.dart';
import '../services/play_queue.dart';
import '../services/season_grouping.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/seek_slider.dart';
import 'detail_screen.dart';
import 'edit_details_screen.dart';

export '../services/play_queue.dart' show AlbumAudioPlayer;

/// One album: big square cover art with the artist and track count, then
/// the tracklist ordered by disc/track number.
///
/// Tracks play RIGHT HERE — tapping a row starts inline audio playback
/// (a shared [PlayQueueController], also behind the playlist page) with
/// the cover art on show (a subtle glow pulse marks it playing) and a
/// transport row: shuffle, previous, play/pause, next, favourite, and a
/// seek bar. Finished tracks roll into the next automatically. The
/// per-track detail page (download, file info) stays reachable from
/// each row's ⓘ button.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.group,
    this.playerFactory,
    this.sourceOverride,
  });

  final HomeAlbum group;

  /// Test override — replaces the media_kit-backed player (widget tests
  /// have no native libmpv).
  final AlbumAudioPlayer Function()? playerFactory;

  /// Test override for the track playback source (widget tests have no
  /// embedded client).
  final ({String url, bool local})? Function(MediaEntry entry)?
      sourceOverride;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen>
    with SingleTickerProviderStateMixin {
  late HomeAlbum _group = widget.group;
  late final PlayQueueController _queue = PlayQueueController(
    tracks: () => _group.tracks,
    trackInfo: _trackInfo,
    playerFactory: widget.playerFactory,
    sourceOverride: widget.sourceOverride,
    confirmCellular: () async =>
        mounted && await confirmCellularStreaming(context) == true,
    pauseDownloadsPrompt: () async =>
        mounted && await maybePauseDownloadsForStreaming(context),
    onMessage: _snack,
  );

  bool _wasPlaying = false;

  late final AnimationController _glow = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    unawaited(FavouritesStore.instance.ensureLoaded());
    _queue.addListener(_onQueue);
  }

  @override
  void dispose() {
    _glow.dispose();
    _queue.removeListener(_onQueue);
    _queue.dispose();
    super.dispose();
  }

  void _onQueue() {
    if (!mounted) return;
    setState(() {});
    if (_queue.playing != _wasPlaying) {
      _wasPlaying = _queue.playing;
      _queue.playing
          ? _glow.repeat(reverse: true)
          : _glow.animateBack(0,
              duration: const Duration(milliseconds: 400));
    }
  }

  /// What the media notification shows for [entry].
  NowPlayingTrack _trackInfo(MediaEntry entry) {
    final meta = MetadataService.instance.metadataFor(entry);
    final parsed = parseMediaName(entry.name);
    final albumMeta =
        MetadataService.instance.metadataFor(_group.tracks.first);
    final credit = albumMeta.albumArtist ??
        (_group.isCompilation
            ? _group.artist
            : albumMeta.artist ?? _group.artist);
    return NowPlayingTrack(
      title: episodeNameFromLabel(meta.episodeLabel) ??
          parsed.trackTitle ??
          entry.name,
      artist: meta.trackArtist ?? credit,
      album: albumMeta.title.isEmpty ? _group.album : albumMeta.title,
      // The playing track's own art beats the album cover, like the
      // page's header.
      artworkPath: meta.episodePosterFilePath ?? meta.posterFilePath,
    );
  }

  /// Re-derive this album's fold from the library — after an edit the
  /// album may have been renamed/merged (the fold reads file names), so
  /// the page must not keep showing the stale pre-edit group. When the
  /// album's tracks are nowhere to be found any more, back out.
  Future<void> _reloadGroup() async {
    final addresses = {
      for (final e in _group.tracks) e.address.toLowerCase(),
    };
    final lists = await LibraryStore.load();
    HomeAlbum? found;
    for (final l in lists) {
      if (l.isChannel || l.isPlaylist) continue;
      for (final item in groupSeasons(l.entries)) {
        if (item is! HomeAlbum) continue;
        if (item.tracks
            .any((e) => addresses.contains(e.address.toLowerCase()))) {
          found = item;
          break;
        }
      }
      if (found != null) break;
    }
    if (!mounted) return;
    if (found == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _group = found!);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Queue every not-yet-downloaded track ([remaining]) for download.
  Future<void> _downloadAll(List<MediaEntry> remaining) async {
    for (final entry in remaining) {
      await DownloadManager.instance.enqueue(entry);
    }
    final n = remaining.length;
    _snack(n == 1
        ? '1 track added to downloads'
        : '$n tracks added to downloads');
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild as the cover art lands in the cache, as downloads change
    // the rows' ticks and the download-all button, as connectivity flips
    // the button's enabled state, and as hearts toggle.
    return ListenableBuilder(
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        ConnectivityMonitor.instance,
        WatchStateStore.instance,
        FavouritesStore.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    final group = _group;
    final current = _queue.current;
    // Any track's match carries the album title, year, and cover art.
    final meta = MetadataService.instance.metadataFor(group.tracks.first);
    final title = meta.title.isEmpty ? group.album : meta.title;
    // The album's displayed credit — a user-set album credit (Edit
    // album details) beats everything, else a compilation's group
    // credit beats any single track's row; track rows show their own
    // artist beside the title when it differs from this.
    final credit = meta.albumArtist ??
        (group.isCompilation ? group.artist : meta.artist ?? group.artist);
    final count = group.tracks.length;
    // Tracks not fully downloaded yet — what "download album" queues.
    final remaining = [
      for (final e in group.tracks)
        if (DownloadManager.instance.taskFor(e.address)?.status !=
            DownloadStatus.done)
          e,
    ];
    // Starting a download needs the network (same gating as DetailScreen);
    // browsing the album stays open.
    final offline = ConnectivityMonitor.instance.offline;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(title,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Add album to playlist',
            icon: Icon(Icons.playlist_add, color: t.boneDim, size: 22),
            onPressed: () =>
                unawaited(addToPlaylistFlow(context, group.tracks)),
          ),
          IconButton(
            tooltip: 'Edit album details',
            icon: Icon(Icons.edit_outlined, color: t.boneDim, size: 20),
            onPressed: () async {
              // Awaited so a rename/merge refolds THIS page immediately
              // (the fold reads file names; the old group is stale the
              // moment Save renames anything).
              await Navigator.of(context).push(
                MaterialPageRoute(
                  // Any track reaches the shared album row.
                  builder: (_) => EditDetailsScreen(
                      entry: group.tracks.first,
                      scope: EditDetailsScope.album,
                      albumIsCompilation: group.isCompilation),
                ),
              );
              await _reloadGroup();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DetailHeader(
            // While a track with its own artwork plays, the cover shows
            // that track's art (entryPosterImage falls back to the
            // album cover for tracks without any).
            poster: _cover(
                t,
                current == null
                    ? posterImage(meta, fit: BoxFit.cover)
                    : entryPosterImage(
                        MetadataService.instance.metadataFor(current),
                        fit: BoxFit.cover)),
            info: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: t.bone,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    credit,
                    if (meta.year != null) '${meta.year}',
                    '$count ${count == 1 ? 'track' : 'tracks'}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 13, color: t.boneDim),
                ),
                const SizedBox(height: 16),
                if (current == null)
                  FilledButton.icon(
                    onPressed: () => unawaited(_queue
                        .playTrack(_queue.nextTrack() ?? group.tracks.first)),
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: const Text('Play album'),
                  ),
                if (current == null) const SizedBox(height: 10),
                if (remaining.isEmpty)
                  OutlinedButton.icon(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      disabledForegroundColor: t.accent,
                      side: BorderSide(color: t.accent),
                    ),
                    icon: const Icon(Icons.download_done, size: 18),
                    label: const Text('Album downloaded'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed:
                        offline ? null : () => _downloadAll(remaining),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: t.bone,
                      side: BorderSide(color: t.ash),
                    ),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(remaining.length == count
                        ? 'Download album'
                        : 'Download remaining (${remaining.length})'),
                  ),
              ],
            ),
          ),
          if (current != null) ...[
            const SizedBox(height: 20),
            _nowPlaying(t),
          ],
          const SizedBox(height: 24),
          sectionLabel(t, 'TRACKS'),
          const SizedBox(height: 4),
          for (final entry in group.tracks)
            _trackRow(context, t, entry, credit),
        ],
      ),
    );
  }

  /// Square cover in the header's artwork slot — album covers are 1:1,
  /// so [headerArtwork]'s 2:3 poster frame would letterbox them. While a
  /// track plays, a subtle accent glow pulses around it.
  Widget _cover(WiTokens t, Widget? image) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: DetailHeader.posterWidth,
        height: DetailHeader.posterWidth,
        child: image ??
            Container(
              color: t.ink2,
              child: Icon(Icons.album_outlined, color: t.ash, size: 96),
            ),
      ),
    );
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        final pulse = Curves.easeInOut.transform(_glow.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: pulse == 0
                ? const []
                : [
                    BoxShadow(
                      color: t.accent.withValues(alpha: 0.14 + 0.18 * pulse),
                      blurRadius: 14 + 12 * pulse,
                      spreadRadius: 1 + 2 * pulse,
                    ),
                  ],
          ),
          child: child,
        );
      },
      child: cover,
    );
  }

  static String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Seek bar + transport controls for the playing track.
  Widget _nowPlaying(WiTokens t) {
    final current = _queue.current!;
    final parsed = parseMediaName(current.name);
    // The playing track's own credit (per-track edit or file-name
    // artist), so compilation tracks and corrected credits show as
    // they play.
    final currentMeta = MetadataService.instance.metadataFor(current);
    final artist = currentMeta.trackArtist;
    final fav = FavouritesStore.instance.isFavourite(current.address);
    final position = _queue.position;
    final duration = _queue.duration;
    final maxMs = duration.inMilliseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          episodeNameFromLabel(currentMeta.episodeLabel) ??
              parsed.trackTitle ??
              current.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: t.bone),
        ),
        if (artist != null) ...[
          const SizedBox(height: 1),
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: t.boneDim),
          ),
        ],
        const SizedBox(height: 2),
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
              icon: Icon(Icons.skip_previous, size: 30, color: t.bone),
            ),
            IconButton.filled(
              tooltip: _queue.playing ? 'Pause' : 'Play',
              style: IconButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: t.ink,
              ),
              onPressed: () => unawaited(_queue.playOrPause()),
              icon: Icon(_queue.playing ? Icons.pause : Icons.play_arrow,
                  size: 30),
            ),
            IconButton(
              tooltip: 'Next track',
              onPressed: _queue.skipNext,
              icon: Icon(Icons.skip_next, size: 30, color: t.bone),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip:
                  fav ? 'Remove from favourites' : 'Add to favourites',
              onPressed: () =>
                  unawaited(FavouritesStore.instance.toggle(current.address)),
              icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                  size: 22, color: fav ? t.accent : t.ash),
            ),
          ],
        ),
      ],
    );
  }

  /// Tracklist row: mono track number (a pulsing-eq mark when playing),
  /// track title — with the track's own artist beside it when that
  /// differs from the album's credit — download tick, and the ⓘ door
  /// to the track's detail page. Tap plays the track right here.
  Widget _trackRow(BuildContext context, WiTokens t, MediaEntry entry,
      String albumCredit) {
    final parsed = parseMediaName(entry.name);
    // The label comes through the metadata service so a user-edited
    // track title (Edit details on the track) shows here too.
    final trackMeta = MetadataService.instance.metadataFor(entry);
    final trackName =
        episodeNameFromLabel(trackMeta.episodeLabel) ?? parsed.trackTitle;
    final ownArtist = trackMeta.trackArtist;
    final showArtist = ownArtist != null && ownArtist != albumCredit;
    final downloaded =
        DownloadManager.instance.taskFor(entry.address)?.status ==
            DownloadStatus.done;
    final isCurrent = _queue.current?.address == entry.address;
    return InkWell(
      onTap: () => unawaited(_queue.playTrack(entry)),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: isCurrent
                  ? Icon(Icons.graphic_eq, size: 16, color: t.accent)
                  : Text(
                      parsed.trackMarker ?? '',
                      style: TextStyle(
                        fontFamily: wiMonoFamily,
                        fontFamilyFallback: wiMonoFallback,
                        fontSize: 12,
                        color: t.accent,
                      ),
                    ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: trackName ?? entry.name,
                  children: [
                    if (showArtist)
                      TextSpan(
                        text: '  ·  $ownArtist',
                        style: TextStyle(
                            fontSize: 12,
                            color: t.ash,
                            fontWeight: FontWeight.w400),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  color: isCurrent ? t.accent : t.bone,
                  fontWeight:
                      isCurrent ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (downloaded) ...[
              const SizedBox(width: 8),
              Icon(Icons.download_done, size: 16, color: t.ash),
            ],
            IconButton(
              tooltip: 'Track details',
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => DetailScreen(entry: entry)),
                );
                // A track edit can rename/refold this very album.
                await _reloadGroup();
              },
              icon: Icon(Icons.info_outline, size: 16, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}
