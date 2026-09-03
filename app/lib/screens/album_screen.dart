import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../models/media_list.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/embedded_client.dart';
import '../services/favourites.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/network_policy.dart';
import '../services/season_grouping.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import 'detail_screen.dart';
import 'edit_details_screen.dart';

/// One album: big square cover art with the artist and track count, then
/// the tracklist ordered by disc/track number.
///
/// Tracks play RIGHT HERE — tapping a row starts inline audio playback
/// with the cover art on show (a subtle glow pulse marks it playing) and
/// a transport row: shuffle, previous, play/pause, next, favourite, and
/// a seek bar. Finished tracks roll into the next automatically. The
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

/// The slice of media_kit's Player the album page uses — injectable so
/// widget tests can fake playback.
abstract class AlbumAudioPlayer {
  Future<void> open(String url);
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;

  /// Emits true when the current track plays to its end.
  Stream<bool> get completedStream;
  Future<void> dispose();
}

class _MediaKitAlbumPlayer implements AlbumAudioPlayer {
  final Player _player = Player();

  @override
  Future<void> open(String url) => _player.open(Media(url));
  @override
  Future<void> playOrPause() => _player.playOrPause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get completedStream => _player.stream.completed;
  @override
  Future<void> dispose() => _player.dispose();
}

class _AlbumScreenState extends State<AlbumScreen>
    with SingleTickerProviderStateMixin {
  AlbumAudioPlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  MediaEntry? _current;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _shuffle = false;

  /// Addresses already played this shuffle pass — shuffle visits every
  /// track once before the album ends.
  final Set<String> _shuffled = {};

  /// Play history for the previous button under shuffle.
  final List<MediaEntry> _history = [];

  /// Downloads paused for this page's streamed playback — resumed when
  /// the page closes or playback stops at the album's end.
  bool _pausedDownloads = false;

  late final AnimationController _glow = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    unawaited(FavouritesStore.instance.ensureLoaded());
  }

  @override
  void dispose() {
    _glow.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_player?.dispose());
    if (_pausedDownloads) {
      unawaited(DownloadManager.instance.resumeAfterPlayback());
    }
    super.dispose();
  }

  AlbumAudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player =
        (widget.playerFactory ?? _MediaKitAlbumPlayer.new).call();
    _player = player;
    _subs.addAll([
      player.playingStream.listen((playing) {
        if (!mounted) return;
        setState(() => _playing = playing);
        playing
            ? _glow.repeat(reverse: true)
            : _glow.animateBack(0, duration: const Duration(milliseconds: 400));
      }),
      player.positionStream.listen((pos) {
        if (mounted) setState(() => _position = pos);
      }),
      player.durationStream.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      }),
      player.completedStream.listen((done) {
        if (done) _onTrackCompleted();
      }),
    ]);
    return player;
  }

  ({String url, bool local})? _sourceFor(MediaEntry e) {
    final override = widget.sourceOverride;
    if (override != null) return override(e);
    final local = DownloadManager.instance.localPathIfDone(e);
    if (local != null) return (url: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), e);
    return url == null ? null : (url: url, local: false);
  }

  Future<void> _playTrack(MediaEntry entry) async {
    final source = _sourceFor(entry);
    if (source == null) {
      _snack('The built-in Autonomi client is not available.');
      return;
    }
    if (!source.local) {
      // Mobile-data policy (Settings → Network), then the shared
      // pause-downloads-while-streaming preference.
      final gate = await streamingGateNow();
      if (gate == StreamingGate.block) {
        _snack("You're on mobile data — streaming is set to Wi-Fi only "
            '(Settings → Network)');
        return;
      }
      if (gate == StreamingGate.ask) {
        if (!mounted) return;
        if (await confirmCellularStreaming(context) != true) return;
        CellularStreamingConsent.granted = true;
      }
      if (!mounted) return;
      if (!_pausedDownloads && DownloadManager.instance.hasActive) {
        _pausedDownloads = await maybePauseDownloadsForStreaming(context);
      }
    }
    if (!mounted) return;
    final player = _ensurePlayer();
    setState(() {
      _current = entry;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    _shuffled.add(entry.address);
    if (_history.isEmpty || _history.last.address != entry.address) {
      _history.add(entry);
    }
    await player.open(source.url);
  }

  /// The track after [entry] in album order, or an unplayed random one
  /// under shuffle; null when the album is done.
  MediaEntry? _nextTrack() {
    final tracks = widget.group.tracks;
    if (_shuffle) {
      final left = [
        for (final e in tracks)
          if (!_shuffled.contains(e.address)) e,
      ];
      if (left.isEmpty) return null;
      return left[Random().nextInt(left.length)];
    }
    final current = _current;
    if (current == null) return tracks.first;
    final i = tracks.indexWhere((e) => e.address == current.address);
    if (i < 0 || i + 1 >= tracks.length) return null;
    return tracks[i + 1];
  }

  void _onTrackCompleted() {
    final next = _nextTrack();
    if (next != null) {
      unawaited(_playTrack(next));
      return;
    }
    // Album finished: reset the shuffle pass and give downloads the
    // network back.
    _shuffled.clear();
    if (_pausedDownloads) {
      _pausedDownloads = false;
      unawaited(DownloadManager.instance.resumeAfterPlayback());
    }
  }

  void _skipNext() {
    final next = _nextTrack();
    if (next != null) unawaited(_playTrack(next));
  }

  /// Previous: restart the track a few seconds in, else step back —
  /// through the play history under shuffle, by album order otherwise.
  void _skipPrevious() {
    if (_position > const Duration(seconds: 3)) {
      unawaited(_player?.seek(Duration.zero));
      return;
    }
    if (_shuffle) {
      if (_history.length < 2) {
        unawaited(_player?.seek(Duration.zero));
        return;
      }
      _history.removeLast();
      final prev = _history.removeLast();
      _shuffled.remove(prev.address);
      unawaited(_playTrack(prev));
      return;
    }
    final tracks = widget.group.tracks;
    final current = _current;
    final i = current == null
        ? -1
        : tracks.indexWhere((e) => e.address == current.address);
    if (i > 0) {
      unawaited(_playTrack(tracks[i - 1]));
    } else {
      unawaited(_player?.seek(Duration.zero));
    }
  }

  void _toggleShuffle() {
    setState(() {
      _shuffle = !_shuffle;
      _shuffled
        ..clear()
        ..addAll(_current == null ? const [] : [_current!.address]);
    });
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
    final group = widget.group;
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
            tooltip: 'Edit album details',
            icon: Icon(Icons.edit_outlined, color: t.boneDim, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                // Any track reaches the shared album row; an album/year
                // rename refolds on the wall when this page is
                // re-entered.
                builder: (_) => EditDetailsScreen(
                    entry: group.tracks.first,
                    scope: EditDetailsScope.album,
                    albumIsCompilation: group.isCompilation),
              ),
            ),
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
                _current == null
                    ? posterImage(meta, fit: BoxFit.cover)
                    : entryPosterImage(
                        MetadataService.instance.metadataFor(_current!),
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
                if (_current == null)
                  FilledButton.icon(
                    onPressed: () =>
                        unawaited(_playTrack(_nextTrack() ?? group.tracks.first)),
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: const Text('Play album'),
                  ),
                if (_current == null) const SizedBox(height: 10),
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
          if (_current != null) ...[
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
    final current = _current!;
    final parsed = parseMediaName(current.name);
    // The playing track's own credit (per-track edit or file-name
    // artist), so compilation tracks and corrected credits show as
    // they play.
    final currentMeta = MetadataService.instance.metadataFor(current);
    final artist = currentMeta.trackArtist;
    final fav = FavouritesStore.instance.isFavourite(current.address);
    final maxMs = _duration.inMilliseconds;
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
            Text(_clock(_position),
                style: TextStyle(
                    fontSize: 11,
                    color: t.ash,
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback)),
            Expanded(
              child: Slider(
                value: maxMs == 0
                    ? 0
                    : _position.inMilliseconds
                        .clamp(0, maxMs)
                        .toDouble(),
                max: maxMs == 0 ? 1 : maxMs.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.ink2,
                onChanged: maxMs == 0
                    ? null
                    : (v) => unawaited(_player
                        ?.seek(Duration(milliseconds: v.round()))),
              ),
            ),
            Text(_clock(_duration),
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
              tooltip: _shuffle ? 'Shuffle off' : 'Shuffle',
              onPressed: _toggleShuffle,
              icon: Icon(Icons.shuffle,
                  size: 22, color: _shuffle ? t.accent : t.ash),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Previous track',
              onPressed: _skipPrevious,
              icon: Icon(Icons.skip_previous, size: 30, color: t.bone),
            ),
            IconButton.filled(
              tooltip: _playing ? 'Pause' : 'Play',
              style: IconButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: t.ink,
              ),
              onPressed: () => unawaited(_player?.playOrPause()),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                  size: 30),
            ),
            IconButton(
              tooltip: 'Next track',
              onPressed: _skipNext,
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
    final isCurrent = _current?.address == entry.address;
    return InkWell(
      onTap: () => unawaited(_playTrack(entry)),
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
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => DetailScreen(entry: entry)),
              ),
              icon: Icon(Icons.info_outline, size: 16, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}
