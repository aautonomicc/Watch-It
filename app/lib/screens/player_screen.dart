import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/connectivity.dart';
import '../services/embedded_client.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/network_pause.dart';
import '../services/now_playing.dart';
import '../services/screen_wake.dart';
import '../services/season_grouping.dart' show episodeNameFromLabel;
import '../services/user_metadata.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';

/// Full-screen video playback of an HTTP stream via media_kit (libmpv).
///
/// Streaming from Autonomi has a slow cold start (every chunk comes off
/// the network the first time), so while mpv is buffering this screen
/// overlays live progress from the embedded client — bytes fetched so
/// far — instead of a bare spinner, and surfaces mpv errors that would
/// otherwise leave the spinner running forever.
///
/// Playback progress is saved as a resume point every few seconds (and
/// on leaving); reaching the end marks the file watched and, for series
/// with a known next episode, offers "Up next" with a short auto-play
/// countdown.
///
/// Music files (audio extension in the name) get an AUDIO layout instead
/// of the video surface — artwork, track title, and simple transport via
/// [AudioPlayerView] — because rendering a Video widget for a music
/// track is a black screen. Same player, resume points, and watch-state
/// recording underneath, so every entry path (Continue Watching, search
/// → detail, album ⓘ → Play) is covered by the one seam.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    required this.entry,
    this.isLocal = false,
    this.resumeFrom = Duration.zero,
    this.nextFor,
    this.sourceFor,
    this.bufferSizeMb = AppSettings.defaultBufferSizeMb,
  });

  final String url;
  final String title;

  /// The library entry being played — keys the resume point.
  final MediaEntry entry;

  /// [url] is a downloaded file on this device rather than a network
  /// stream — the buffering overlay skips the network-progress copy.
  final bool isLocal;

  /// Start playback here instead of the beginning (Resume button).
  final Duration resumeFrom;

  /// Resolves the episode after [entry] within its show (null for movies
  /// and final episodes) — enables the end-of-episode "Up next" flow,
  /// including across auto-advanced episodes.
  final MediaEntry? Function(MediaEntry entry)? nextFor;

  /// Resolves the playback source for a chained next episode (downloaded
  /// file or network stream). Falls back to streaming when null.
  final ({String url, bool local})? Function(MediaEntry entry)? sourceFor;

  /// mpv demuxer cache cap (Settings → Streaming → Buffer size).
  final int bufferSizeMb;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<VideoParams>? _videoParamsSub;
  Timer? _healthTimer;
  Timer? _countdownTimer;

  bool _buffering = true;
  bool _playbackStarted = false;
  String? _error;
  int _fetchedBytes = 0;

  /// What is playing right now — advances past [widget.entry] when the
  /// user rolls into the next episode.
  late MediaEntry _entry;
  late String _title;
  late bool _isLocal;

  Duration _position = Duration.zero;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Mirrored player state for the audio layout (the video layout's
  /// stock controls track these themselves).
  Duration _duration = Duration.zero;
  bool _playing = false;

  /// The playing file is music — swaps the video surface for the audio
  /// layout and skips the screensaver inhibit (music with the screen
  /// off is the point).
  bool get _isAudio => parseMediaName(_entry.name).isAudio;

  /// End reached for [_entry] (watched state already recorded).
  bool _completed = false;

  /// The episode offered by the "Up next" overlay, when one exists.
  MediaEntry? _upNext;
  int _countdown = 0;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    _title = widget.title;
    _isLocal = widget.isLocal;
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: widget.bufferSizeMb * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Cold chunk fetches can exceed mpv's default 60s network timeout,
      // which kills playback with no visible error. Give the network room.
      platform.setProperty('network-timeout', '300');
    }
    _bufferingSub = _player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    });
    // Linux screensaver/lock inhibit while playback runs — the wakelock the
    // Video widget holds covers the other platforms (see ScreenWake docs).
    _playingSub = _player.stream.playing.listen((playing) {
      if (!_isAudio) ScreenWake.instance.setPlaying(playing);
      if (mounted) setState(() => _playing = playing);
      // Feeds the idle auto-pause: while something plays the network
      // never pauses itself, and pressing play lifts an automatic pause.
      NetworkPause.instance.setStreamingActive(this, playing);
      NowPlaying.instance.updatePlayback(this, playing: playing);
    });
    // mpv reports error-level log lines that are not fatal — e.g. a
    // hardware decoder that fails to open ("could not open codec")
    // right before it falls back to software and plays fine. Only treat
    // an error as fatal while nothing has played yet; once frames are
    // rendering, errors would show a "Playback failed" overlay on top
    // of a working video.
    _errorSub = _player.stream.error.listen((e) {
      if (mounted && !_playbackStarted) setState(() => _error = e);
    });
    _positionSub = _player.stream.position.listen(_onPosition);
    _durationSub = _player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _onCompleted();
    });
    _videoParamsSub = _player.stream.videoParams.listen(_onVideoParams);
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_isLocal || !_buffering || _error != null) return;
      final health = await EmbeddedClient.health();
      if (mounted) setState(() => _fetchedBytes = health.fetchedBytes);
    });
    _feedNowPlaying();
    unawaited(() async {
      // An idle auto-pause lifts the moment the user plays something —
      // cleared before mpv's first request can hit the local server.
      await NetworkPause.instance.noteActivity();
      await _player.open(Media(
        widget.url,
        start: widget.resumeFrom > Duration.zero ? widget.resumeFrom : null,
      ));
    }());
  }

  /// Music files opened via the detail page get the media notification
  /// (screen-off playback + lock-screen controls). Video stays out on
  /// purpose: it holds a screen wakelock while watched and stops
  /// mattering when backgrounded.
  void _feedNowPlaying() {
    if (!parseMediaName(_entry.name).isAudio) return;
    final meta = MetadataService.instance.metadataFor(_entry);
    final parsed = parseMediaName(_entry.name);
    NowPlaying.instance.setTrack(
      this,
      NowPlayingTrack(
        // For music, meta.title is the album; the track's own name comes
        // from its edited label or the parsed file name.
        title: episodeNameFromLabel(meta.episodeLabel) ??
            parsed.trackTitle ??
            meta.title,
        artist: meta.trackArtist ?? meta.artist,
        album: parsed.trackMarker == null ? null : meta.title,
        artworkPath: meta.episodePosterFilePath ?? meta.posterFilePath,
      ),
      handlers: NowPlayingHandlers(
        onPlay: () => unawaited(_player.play()),
        onPause: () => unawaited(_player.pause()),
        onSeek: (pos) => unawaited(_player.seek(pos)),
        onStop: () => unawaited(_player.pause()),
      ),
    );
  }

  /// Addresses whose resolution was recorded this session (mpv re-emits
  /// params on seeks and track changes).
  final Set<String> _resolutionNoted = {};

  /// Learn the playing file's resolution from mpv and persist it as the
  /// entry's format label — imported datamaps have no way to know it
  /// before first playback. Entries that already carry a label (the
  /// seed catalog's probed `480p H.264`) are left alone.
  void _onVideoParams(VideoParams params) {
    final h = params.dh ?? params.h;
    if (h == null || h <= 0) return;
    if (_entry.videoInfo != null && _entry.videoInfo!.isNotEmpty) return;
    if (!_resolutionNoted.add(_entry.address.toLowerCase())) return;
    unawaited(LibraryStore.noteEntryInfo(_entry.address,
        videoInfo: resolutionLabel(h)));
  }

  void _onPosition(Duration pos) {
    if (pos <= Duration.zero) return;
    _position = pos;
    // The audio layout draws its own seek bar off _position.
    if (_isAudio && mounted) setState(() {});
    NowPlaying.instance.updatePlayback(this,
        position: pos, duration: _player.state.duration);
    if (!_playbackStarted) {
      _playbackStarted = true;
      // Playback is demonstrably working — drop any earlier error
      // (a failed decoder attempt that mpv recovered from).
      if (mounted) setState(() => _error = null);
    }
    // Throttled resume-point save; the final position is saved in
    // dispose so quitting mid-playback loses at most nothing.
    final now = DateTime.now();
    if (now.difference(_lastSave) >= const Duration(seconds: 5)) {
      _lastSave = now;
      _saveProgress();
    }
  }

  void _saveProgress() {
    // Nothing to save before the first frame (a start-and-quit during
    // buffering must not wipe an existing resume point), and nothing
    // after the end was recorded as watched.
    if (!_playbackStarted || _completed || _position <= Duration.zero) return;
    unawaited(WatchStateStore.instance.record(
      _entry,
      position: _position,
      duration: _player.state.duration,
    ));
  }

  void _onCompleted() {
    if (!_playbackStarted || _completed) return;
    _completed = true;
    unawaited(WatchStateStore.instance
        .markCompleted(_entry, duration: _player.state.duration));
    final next = widget.nextFor?.call(_entry);
    if (next == null || !mounted) return;
    // Chain rule: a downloaded next episode always chains; a streamed
    // one needs the network — offline the chain stops here, with no
    // skipping ahead to a later downloaded episode. Live probe, so a
    // connection lost mid-episode is caught between poll ticks.
    final nextIsLocal = widget.sourceFor?.call(next)?.local ?? false;
    unawaited(() async {
      final chain = await canChainInto(nextIsLocal: nextIsLocal);
      if (!chain || !mounted || !_completed || _upNext != null) return;
      setState(() {
        _upNext = next;
        _countdown = 10;
      });
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_countdown <= 1) {
          _playNext();
        } else {
          setState(() => _countdown--);
        }
      });
    }());
  }

  /// Roll straight into the next episode inside this player. The
  /// pause-downloads decision made for the first episode carries over —
  /// chaining never re-prompts.
  void _playNext() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    final next = _upNext;
    if (next == null) return;
    final fallback = streamUrl(EmbeddedClient.baseUrl(), next);
    final source = widget.sourceFor?.call(next) ??
        (fallback == null ? null : (url: fallback, local: false));
    if (source == null) return;
    final meta = MetadataService.instance.metadataFor(next);
    setState(() {
      _entry = next;
      _title = playerTitle(meta);
      _isLocal = source.local;
      _upNext = null;
      _completed = false;
      _playbackStarted = false;
      _buffering = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    _feedNowPlaying();
    _player.open(Media(source.url));
  }

  void _dismissUpNext() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    setState(() => _upNext = null);
  }

  /// "Use this frame as artwork": grab the current video frame off mpv
  /// and save it as the playing entry's user poster (pause at the
  /// perfect moment, tap the camera). The companion to Edit details'
  /// sampled-frame picker; the row keeps its displayed title/details.
  Future<void> _useFrameAsPoster() async {
    final bytes = await _player.screenshot();
    if (!mounted) return;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No frame to capture yet — wait for the video '
              'to start.')));
      return;
    }
    final key = parseMediaName(_entry.name).lookupKey;
    final meta = MetadataService.instance.metadataFor(_entry);
    final name = await saveUserPoster(key, bytes);
    await saveUserDetails(
      lookupKey: key,
      title: meta.title,
      year: meta.year,
      overview: meta.overview,
      posterFile: Value(name),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Frame saved as this title\'s artwork')));
  }

  @override
  void dispose() {
    _saveProgress();
    _healthTimer?.cancel();
    _countdownTimer?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();
    ScreenWake.instance.setPlaying(false);
    NetworkPause.instance.setStreamingActive(this, false);
    NowPlaying.instance.clear(this);
    _errorSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Widget _bufferingOverlay(BuildContext context) {
    final t = WiTokens.of(context);
    if (_isLocal) {
      // Local files open near-instantly — no network progress to narrate.
      return Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: CircularProgressIndicator(color: t.accent),
      );
    }
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: t.accent),
          const SizedBox(height: 16),
          Text(
            'Fetching from the Autonomi network…',
            style: TextStyle(color: t.bone, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            _fetchedBytes > 0
                ? '${byteLabel(_fetchedBytes)} retrieved'
                : 'waiting for first chunks',
            style: TextStyle(color: t.boneDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Text(
            'First start can take a few minutes\nwhile chunks are located.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.ash, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _errorOverlay(BuildContext context) {
    final t = WiTokens.of(context);
    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: t.accent, size: 40),
          const SizedBox(height: 12),
          Text(
            'Playback failed',
            style: TextStyle(
                color: t.bone, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.boneDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Bottom "Up next" banner shown when an episode ends: the next
  /// episode's name with an auto-play countdown, Play now, and dismiss.
  Widget _upNextOverlay(BuildContext context, MediaEntry next) {
    final t = WiTokens.of(context);
    final meta = MetadataService.instance.metadataFor(next);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
        decoration: BoxDecoration(
          color: t.ink2.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'UP NEXT',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.accent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    playerTitle(meta),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: t.bone,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Playing in $_countdown s',
                    style: TextStyle(fontSize: 11.5, color: t.boneDim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            FilledButton(
              onPressed: _playNext,
              style: FilledButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: t.ink,
              ),
              child: const Text('Play now'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: _dismissUpNext,
              icon: Icon(Icons.close, color: t.boneDim, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_title, style: const TextStyle(fontSize: 15)),
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Music: artwork + transport instead of a black video surface
            // (no frame-capture button — there are no frames).
            if (_isAudio)
              AudioPlayerView(
                entry: _entry,
                position: _position,
                duration: _duration,
                playing: _playing,
                onPlayPause: () => unawaited(_player.playOrPause()),
                onSeek: (pos) => unawaited(_player.seek(pos)),
              )
            else
            // The stock controls draw their own grey buffering spinner in
            // the centre of the video; our branded overlay already covers
            // buffering, so blank out the built-in one on all platforms.
            // The bottom controls default to zero bottom margin, which puts
            // them on top of the Android navigation buttons — lift them
            // clear, and draw the seek bar at twice the stock thickness.
            MaterialVideoControlsTheme(
              normal: kDefaultMaterialVideoControlsThemeData.copyWith(
                bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                bottomButtonBarMargin:
                    const EdgeInsets.only(left: 16, right: 8, bottom: 48),
                seekBarMargin:
                    const EdgeInsets.only(left: 16, right: 16, bottom: 48),
                seekBarHeight: 4.8,
                topButtonBar: [
                  const Spacer(),
                  MaterialCustomButton(
                    onPressed: () => unawaited(_useFrameAsPoster()),
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                ],
              ),
              fullscreen:
                  kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(
                bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                bottomButtonBarMargin:
                    const EdgeInsets.only(left: 16, right: 8, bottom: 64),
                seekBarMargin:
                    const EdgeInsets.only(left: 16, right: 16, bottom: 64),
                seekBarHeight: 4.8,
                topButtonBar: [
                  const Spacer(),
                  MaterialCustomButton(
                    onPressed: () => unawaited(_useFrameAsPoster()),
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                ],
              ),
              child: MaterialDesktopVideoControlsTheme(
                normal: desktopControlsTheme(
                    kDefaultMaterialDesktopVideoControlsThemeData,
                    topButtonBar: [
                      const Spacer(),
                      MaterialDesktopCustomButton(
                        onPressed: () => unawaited(_useFrameAsPoster()),
                        icon: const Icon(Icons.photo_camera_outlined),
                      ),
                    ]),
                fullscreen: desktopControlsTheme(
                    kDefaultMaterialDesktopVideoControlsThemeDataFullscreen,
                    topButtonBar: [
                      const Spacer(),
                      MaterialDesktopCustomButton(
                        onPressed: () => unawaited(_useFrameAsPoster()),
                        icon: const Icon(Icons.photo_camera_outlined),
                      ),
                    ]),
                child: Video(controller: _controller),
              ),
            ),
            if (_error != null)
              _errorOverlay(context)
            else if (_buffering)
              _bufferingOverlay(context),
            if (_upNext != null) _upNextOverlay(context, _upNext!),
          ],
        ),
      ),
    );
  }
}

/// Player/app-bar title for [meta]: `Show · S01E02 · Name` for episodes,
/// the plain title otherwise.
String playerTitle(MediaMetadata meta) => meta.episodeLabel == null
    ? meta.title
    : '${meta.title} · ${meta.episodeLabel}';

/// The audio layout [PlayerScreen] shows for music: square artwork
/// (the track's own art beats the album cover), track title and credit,
/// a seek bar, and play/pause with ±10s/30s skips. The heavy lifting —
/// mpv, resume points, watch states, the media notification — stays in
/// [PlayerScreen]; this widget only renders and forwards taps.
class AudioPlayerView extends StatelessWidget {
  const AudioPlayerView({
    super.key,
    required this.entry,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onSeek,
  });

  final MediaEntry entry;
  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;

  static String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _seekBy(Duration delta) {
    var target = position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    onSeek(target);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    // Rebuild as the artwork lands in the metadata cache.
    return ListenableBuilder(
      listenable: MetadataService.instance,
      builder: (context, _) {
        final meta = MetadataService.instance.metadataFor(entry);
        final parsed = parseMediaName(entry.name);
        final trackTitle = episodeNameFromLabel(meta.episodeLabel) ??
            parsed.trackTitle ??
            meta.title;
        final artist = meta.trackArtist ?? meta.artist;
        // For music meta.title is the album — show it under the credit
        // when this is a numbered album track.
        final album = parsed.trackMarker == null ? null : meta.title;
        final maxMs = duration.inMilliseconds;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: 320, maxHeight: 320),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: entryPosterImage(meta, fit: BoxFit.cover) ??
                            Container(
                              color: t.ink2,
                              child: Icon(Icons.music_note,
                                  color: t.ash, size: 96),
                            ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                trackTitle,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: t.bone),
              ),
              if (artist != null || album != null) ...[
                const SizedBox(height: 4),
                Text(
                  [artist, album].nonNulls.join(' · '),
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: t.boneDim),
                ),
              ],
              const SizedBox(height: 8),
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
                          : position.inMilliseconds
                              .clamp(0, maxMs)
                              .toDouble(),
                      max: maxMs == 0 ? 1 : maxMs.toDouble(),
                      activeColor: t.accent,
                      inactiveColor: t.ink2,
                      onChanged: maxMs == 0
                          ? null
                          : (v) =>
                              onSeek(Duration(milliseconds: v.round())),
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
                    tooltip: 'Back 10 seconds',
                    onPressed: () => _seekBy(const Duration(seconds: -10)),
                    icon: Icon(Icons.replay_10, size: 28, color: t.bone),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: playing ? 'Pause' : 'Play',
                    style: IconButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: t.ink,
                    ),
                    onPressed: onPlayPause,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow,
                        size: 32),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Forward 30 seconds',
                    onPressed: () => _seekBy(const Duration(seconds: 30)),
                    icon: Icon(Icons.forward_30, size: 28, color: t.bone),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Desktop controls theme tweaks: the branded overlay replaces the stock
/// buffering spinner, and the mouse cursor fades out with the controls
/// instead of sitting on the film forever. [topButtonBar] carries the
/// screen's own buttons (frame-as-artwork capture).
MaterialDesktopVideoControlsThemeData desktopControlsTheme(
        MaterialDesktopVideoControlsThemeData base,
        {List<Widget> topButtonBar = const []}) =>
    base.copyWith(
      bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
      hideMouseOnControlsRemoval: true,
      topButtonBar: topButtonBar,
    );
