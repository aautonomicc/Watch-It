import 'package:flutter/foundation.dart';

/// Metadata for the audibly playing track — what the platform media
/// notification (and lock screen) shows.
class NowPlayingTrack {
  const NowPlayingTrack({
    required this.title,
    this.artist,
    this.album,
    this.artworkPath,
  });

  final String title;
  final String? artist;
  final String? album;

  /// Absolute path of a cover/poster image file on this device, when one
  /// is cached (the platform side decodes it for the notification).
  final String? artworkPath;
}

/// Remote-control handlers the active player registers — invoked when a
/// notification button, lock-screen control, headset button, or audio
/// focus change asks for the action. Absent handlers are ignored.
class NowPlayingHandlers {
  const NowPlayingHandlers({
    this.onPlay,
    this.onPause,
    this.onNext,
    this.onPrevious,
    this.onSeek,
    this.onStop,
  });

  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final void Function(Duration position)? onSeek;

  /// The session was told to end from outside (notification dismissed).
  final VoidCallback? onStop;
}

/// The one source of truth for "what is audibly playing": fed by
/// whichever audio player is active (the album page's inline player, or
/// PlayerScreen for music files opened via the detail page), mirrored
/// into the Android media notification by [MediaSessionBridge].
///
/// Sessions are owner-keyed: the player that most recently called
/// [setTrack] owns the session, stale updates from a previous player are
/// ignored, and only the owner's [clear] ends the session.
class NowPlaying extends ChangeNotifier {
  /// Replaceable for tests (fresh instance per test).
  static NowPlaying instance = NowPlaying();

  Object? _owner;
  NowPlayingTrack? _track;
  NowPlayingHandlers _handlers = const NowPlayingHandlers();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _canNext = false;
  bool _canPrev = false;

  /// Null while nothing owns the session (no media notification shown).
  NowPlayingTrack? get track => _track;
  bool get playing => _playing;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get canNext => _canNext;
  bool get canPrev => _canPrev;

  /// Take over the session for [owner] and show [track]. The previous
  /// owner (if different) is silently superseded — its later updates
  /// no-op.
  void setTrack(
    Object owner,
    NowPlayingTrack track, {
    required NowPlayingHandlers handlers,
    bool canNext = false,
    bool canPrev = false,
  }) {
    _owner = owner;
    _track = track;
    _handlers = handlers;
    _canNext = canNext;
    _canPrev = canPrev;
    // Playback state resets until the (possibly new) owner reports.
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
  }

  /// Live playback state from the owning player. Ignored from anyone
  /// else (a superseded player's streams keep emitting until disposed).
  void updatePlayback(
    Object owner, {
    bool? playing,
    Duration? position,
    Duration? duration,
  }) {
    if (owner != _owner || _track == null) return;
    var changed = false;
    if (playing != null && playing != _playing) {
      _playing = playing;
      changed = true;
    }
    if (position != null && position != _position) {
      _position = position;
      changed = true;
    }
    if (duration != null && duration != _duration) {
      _duration = duration;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// End the session — the media notification goes away. No-op unless
  /// [owner] still owns it (a superseded player disposing later must not
  /// kill the new session).
  void clear(Object owner) {
    if (owner != _owner) return;
    _owner = null;
    _track = null;
    _handlers = const NowPlayingHandlers();
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _canNext = false;
    _canPrev = false;
    notifyListeners();
  }

  // Remote control entry points (notification buttons, headset,
  // audio-focus changes) — dispatched to the owner's handlers.
  void remotePlay() => _handlers.onPlay?.call();
  void remotePause() => _handlers.onPause?.call();
  void remoteNext() => _handlers.onNext?.call();
  void remotePrevious() => _handlers.onPrevious?.call();
  void remoteSeek(Duration position) => _handlers.onSeek?.call(position);

  /// The platform ended the session (notification dismissed while
  /// paused): tell the owner, then clear.
  void remoteStop() {
    _handlers.onStop?.call();
    final owner = _owner;
    if (owner != null) clear(owner);
  }
}
