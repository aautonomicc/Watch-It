import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/media_list.dart';
import 'download_manager.dart';
import 'embedded_client.dart';
import 'network_pause.dart';
import 'network_policy.dart';
import 'now_playing.dart';
import 'watch_state.dart';

/// The slice of media_kit's Player the audio queue uses — injectable so
/// widget tests can fake playback. (Historically `AlbumAudioPlayer` on
/// the album screen; the queue moved here 2026-09-11 so the playlist
/// page shares it.)
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

class _MediaKitAudioPlayer implements AlbumAudioPlayer {
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

/// The shared inline audio queue: ordered tracks, shuffle with a
/// no-repeat pass, auto-advance on completion, watch-state recording
/// (resume points + completion), the media notification (lock-screen
/// prev/next), idle auto-pause activity, and the streaming gates
/// (cellular policy, pause-downloads-while-streaming). Owned by the
/// screen that starts playback — the album page and the playlist page
/// both drive one of these; the screen renders off [ChangeNotifier]
/// notifications.
class PlayQueueController extends ChangeNotifier {
  PlayQueueController({
    required this.tracks,
    required this.trackInfo,
    AlbumAudioPlayer Function()? playerFactory,
    this.sourceOverride,
    this.confirmCellular,
    this.pauseDownloadsPrompt,
    this.onMessage,
  }) : _playerFactory = playerFactory ?? _MediaKitAudioPlayer.new;

  /// The queue's track order — read fresh on every advance, so a
  /// reordered playlist takes effect from the next track on.
  final List<MediaEntry> Function() tracks;

  /// What the media notification shows for a track (album and playlist
  /// pages label tracks differently).
  final NowPlayingTrack Function(MediaEntry entry) trackInfo;

  final AlbumAudioPlayer Function() _playerFactory;

  /// Test override for the track playback source (widget tests have no
  /// embedded client).
  final ({String url, bool local})? Function(MediaEntry entry)?
      sourceOverride;

  /// Asked before streaming on mobile data with the Ask policy; null =
  /// refuse (headless use). The owning screen passes a dialog.
  final Future<bool> Function()? confirmCellular;

  /// Asked once per session before streaming while downloads run;
  /// returns whether downloads were paused for this playback.
  final Future<bool> Function()? pauseDownloadsPrompt;

  /// Where user-facing failures land (the owning screen's snackbar).
  final void Function(String message)? onMessage;

  AlbumAudioPlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  MediaEntry? _current;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _shuffle = false;

  /// Addresses already played this shuffle pass — shuffle visits every
  /// track once before the queue ends.
  final Set<String> _shuffled = {};

  /// Play history for the previous button under shuffle.
  final List<MediaEntry> _history = [];

  /// Downloads paused for this queue's streamed playback — resumed when
  /// the owner disposes the queue or playback stops at the end.
  bool _pausedDownloads = false;

  /// Throttle for the resume-point save, like PlayerScreen's.
  DateTime _lastStateSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// The playing track already recorded as completed — the final
  /// position save must not reopen it.
  bool _trackCompleted = false;

  MediaEntry? get current => _current;
  bool get playing => _playing;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get shuffle => _shuffle;

  @override
  void dispose() {
    saveProgress();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_player?.dispose());
    NowPlaying.instance.clear(this);
    NetworkPause.instance.setStreamingActive(this, false);
    if (_pausedDownloads) {
      unawaited(DownloadManager.instance.resumeAfterPlayback());
    }
    super.dispose();
  }

  AlbumAudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _playerFactory();
    _player = player;
    _subs.addAll([
      player.playingStream.listen((playing) {
        // Feeds the idle auto-pause (see NetworkPause): audio playing
        // here counts as network activity like the video player's.
        NetworkPause.instance.setStreamingActive(this, playing);
        // …and the media notification's play/pause state.
        NowPlaying.instance.updatePlayback(this, playing: playing);
        _playing = playing;
        notifyListeners();
      }),
      player.positionStream.listen((pos) {
        NowPlaying.instance.updatePlayback(this, position: pos);
        _position = pos;
        notifyListeners();
        // Throttled resume-point save — tracks played here reach
        // Continue Watching like anything played in PlayerScreen; the
        // final position is saved in dispose.
        final now = DateTime.now();
        if (pos > Duration.zero &&
            now.difference(_lastStateSave) >= const Duration(seconds: 5)) {
          _lastStateSave = now;
          saveProgress();
        }
      }),
      player.durationStream.listen((dur) {
        NowPlaying.instance.updatePlayback(this, duration: dur);
        _duration = dur;
        notifyListeners();
      }),
      player.completedStream.listen((done) {
        if (done) _onTrackCompleted();
      }),
    ]);
    return player;
  }

  /// Record the playing track's resume point (skipped once its end was
  /// recorded, and before any real progress — a tap-and-close must not
  /// wipe an existing resume point).
  void saveProgress() {
    final current = _current;
    if (current == null || _trackCompleted || _position <= Duration.zero) {
      return;
    }
    unawaited(WatchStateStore.instance
        .record(current, position: _position, duration: _duration));
  }

  ({String url, bool local})? _sourceFor(MediaEntry e) {
    final override = sourceOverride;
    if (override != null) return override(e);
    final local = DownloadManager.instance.localPathIfDone(e);
    if (local != null) return (url: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), e);
    return url == null ? null : (url: url, local: false);
  }

  Future<void> playTrack(MediaEntry entry) async {
    final source = _sourceFor(entry);
    if (source == null) {
      onMessage?.call('The built-in Autonomi client is not available.');
      return;
    }
    if (!source.local) {
      // Mobile-data policy (Settings → Network), then the shared
      // pause-downloads-while-streaming preference.
      final gate = await streamingGateNow();
      if (gate == StreamingGate.block) {
        onMessage?.call(
            "You're on mobile data — streaming is set to Wi-Fi only "
            '(Settings → Network)');
        return;
      }
      if (gate == StreamingGate.ask) {
        if (await confirmCellular?.call() != true) return;
        CellularStreamingConsent.granted = true;
      }
      if (!_pausedDownloads && DownloadManager.instance.hasActive) {
        _pausedDownloads = await pauseDownloadsPrompt?.call() ?? false;
      }
    }
    final player = _ensurePlayer();
    _current = entry;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
    _trackCompleted = false;
    _shuffled.add(entry.address);
    if (_history.isEmpty || _history.last.address != entry.address) {
      _history.add(entry);
    }
    _feedNowPlaying(entry);
    // Lift an idle auto-pause before the stream request hits the core.
    await NetworkPause.instance.noteActivity();
    await player.open(source.url);
  }

  /// Hand the media notification (lock-screen controls, headset buttons)
  /// this track's info and this queue's transport as its handlers.
  void _feedNowPlaying(MediaEntry entry) {
    NowPlaying.instance.setTrack(
      this,
      trackInfo(entry),
      handlers: NowPlayingHandlers(
        onPlay: () {
          if (!_playing) unawaited(_player?.playOrPause());
        },
        onPause: () {
          if (_playing) unawaited(_player?.playOrPause());
        },
        onNext: skipNext,
        onPrevious: skipPrevious,
        onSeek: (pos) => unawaited(_player?.seek(pos)),
        onStop: () {
          if (_playing) unawaited(_player?.playOrPause());
        },
      ),
      canNext: true,
      canPrev: true,
    );
  }

  /// The track after the current one in queue order, or an unplayed
  /// random one under shuffle; null when the queue is done.
  MediaEntry? nextTrack() {
    final list = tracks();
    if (list.isEmpty) return null;
    if (_shuffle) {
      final left = [
        for (final e in list)
          if (!_shuffled.contains(e.address)) e,
      ];
      if (left.isEmpty) return null;
      return left[Random().nextInt(left.length)];
    }
    final current = _current;
    if (current == null) return list.first;
    final i = list.indexWhere((e) => e.address == current.address);
    if (i < 0 || i + 1 >= list.length) return null;
    return list[i + 1];
  }

  void _onTrackCompleted() {
    // Reaching the end marks the track watched (completed music never
    // clutters Continue Watching — only partial listens resume there).
    final finished = _current;
    if (finished != null && !_trackCompleted) {
      _trackCompleted = true;
      unawaited(WatchStateStore.instance
          .markCompleted(finished, duration: _duration));
    }
    final next = nextTrack();
    if (next != null) {
      unawaited(playTrack(next));
      return;
    }
    // Queue finished: reset the shuffle pass and give downloads the
    // network back.
    _shuffled.clear();
    if (_pausedDownloads) {
      _pausedDownloads = false;
      unawaited(DownloadManager.instance.resumeAfterPlayback());
    }
  }

  void skipNext() {
    final next = nextTrack();
    if (next != null) unawaited(playTrack(next));
  }

  /// Previous: restart the track a few seconds in, else step back —
  /// through the play history under shuffle, by queue order otherwise.
  void skipPrevious() {
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
      unawaited(playTrack(prev));
      return;
    }
    final list = tracks();
    final current = _current;
    final i = current == null
        ? -1
        : list.indexWhere((e) => e.address == current.address);
    if (i > 0) {
      unawaited(playTrack(list[i - 1]));
    } else {
      unawaited(_player?.seek(Duration.zero));
    }
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _shuffled
      ..clear()
      ..addAll(_current == null ? const [] : [_current!.address]);
    notifyListeners();
  }

  Future<void> playOrPause() async => _player?.playOrPause();

  Future<void> seek(Duration position) async => _player?.seek(position);
}
