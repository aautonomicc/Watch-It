import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Remote-only transport, independent of the native player for key testing.
/// Select reveals controls; once visible, arrows navigate and Select activates.
/// Dedicated media keys work even when the overlay is hidden.
class TvPlayerControls extends StatefulWidget {
  const TvPlayerControls({
    super.key,
    required this.child,
    required this.title,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onSeek,
    required this.onExit,
    this.onNext,
    this.onTracks,
    this.captions,
    this.inset = EdgeInsets.zero,
  });
  final Widget child;
  final String title;
  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onExit;
  final VoidCallback? onNext;
  final Future<void> Function()? onTracks;

  /// The caption layer is laid out above the transport, including while paused.
  final Widget? captions;

  /// Safe-area padding for the overlays only: with full-bleed video the
  /// child renders edge to edge while the top bar, captions and transport
  /// stay inside the TV overscan margins.
  final EdgeInsets inset;

  @override
  State<TvPlayerControls> createState() => _TvPlayerControlsState();
}

class _TvPlayerControlsState extends State<TvPlayerControls> {
  final _remote = FocusNode(
    debugLabel: 'TV player remote',
    skipTraversal: true,
  );
  final _play = FocusNode(debugLabel: 'TV play pause');
  final _timeline = FocusNode(debugLabel: 'TV seek timeline');
  Duration? _scrubPosition;
  Timer? _timer;
  bool _visible = true;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(TvPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _scheduleHide();
  }

  void _scheduleHide() {
    _timer?.cancel();
    if (_visible &&
        widget.playing &&
        !_menuOpen &&
        !_timeline.hasFocus &&
        _scrubPosition == null) {
      _timer = Timer(const Duration(seconds: 6), _hide);
    }
  }

  void _hide() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _visible = false;
      _scrubPosition = null;
    });
    _remote.requestFocus();
  }

  void _show() {
    setState(() => _visible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visible) _play.requestFocus();
    });
    _scheduleHide();
  }

  void _seek(int seconds) {
    if (widget.duration <= Duration.zero) return;
    final ms = (widget.position.inMilliseconds + seconds * 1000).clamp(
      0,
      widget.duration.inMilliseconds,
    );
    widget.onSeek(Duration(milliseconds: ms));
    _show();
  }

  void _preview(double milliseconds) {
    if (widget.duration <= Duration.zero) return;
    _timer?.cancel();
    setState(
      () => _scrubPosition = Duration(
        milliseconds: milliseconds.round().clamp(
          0,
          widget.duration.inMilliseconds,
        ),
      ),
    );
  }

  void _commitScrub() {
    final target = _scrubPosition;
    if (target == null) return;
    widget.onSeek(target);
    setState(() => _scrubPosition = null);
    _show();
  }

  void _cancelScrub() {
    setState(() => _scrubPosition = null);
    _scheduleHide();
  }

  KeyEventResult _timelineKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final base = _scrubPosition ?? widget.position;
      _preview(
        (base.inMilliseconds +
                (key == LogicalKeyboardKey.arrowRight ? 10000 : -10000))
            .toDouble(),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent) {
        if (_scrubPosition == null) {
          _preview(widget.position.inMilliseconds.toDouble());
        } else {
          _commitScrub();
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggle() {
    widget.onPlayPause();
    _show();
  }

  Future<void> _openTracks() async {
    if (_menuOpen || widget.onTracks == null) return;
    _menuOpen = true;
    _timer?.cancel();
    try {
      await widget.onTracks!();
    } finally {
      _menuOpen = false;
      if (mounted) _show();
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    _scheduleHide();
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) _toggle();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.mediaPlay) != widget.playing) {
        _toggle();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaFastForward) {
      _seek(key == LogicalKeyboardKey.mediaRewind ? -10 : 10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext && widget.onNext != null) {
      if (event is KeyDownEvent) widget.onNext!();
      return KeyEventResult.handled;
    }
    if (!_visible &&
        [
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ].contains(key)) {
      _show();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_scrubPosition != null) {
        _cancelScrub();
      } else if (_visible) {
        _hide();
      } else {
        widget.onExit();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 86400000);
    final minutes = (seconds ~/ 60) % 60;
    final tail =
        '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return seconds >= 3600 ? '${seconds ~/ 3600}:$tail' : tail;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _remote.dispose();
    _play.dispose();
    _timeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_visible,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        if (_scrubPosition != null) {
          _cancelScrub();
        } else {
          _hide();
        }
      }
    },
    child: Focus(
      focusNode: _remote,
      onKeyEvent: _key,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_visible) ...[
            Padding(
              padding: widget.inset,
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: widget.onExit,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back to library'),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          Padding(
            padding: widget.inset,
            child: Column(
              children: [
                Expanded(
                  child: IgnorePointer(
                    child: widget.captions ?? const SizedBox.expand(),
                  ),
                ),
                if (_visible)
                  Container(
                    key: const ValueKey('tv-transport'),
                    color: Colors.black87,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              _clock(_scrubPosition ?? widget.position),
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Focus(
                                focusNode: _timeline,
                                canRequestFocus:
                                    widget.duration > Duration.zero,
                                descendantsAreFocusable: false,
                                onKeyEvent: _timelineKey,
                                onFocusChange: (focused) {
                                  if (!mounted) return;
                                  if (!focused && _scrubPosition != null) {
                                    setState(() => _scrubPosition = null);
                                  }
                                  _scheduleHide();
                                },
                                child: Semantics(
                                  label: 'Playback position',
                                  child: Slider(
                                    key: const ValueKey('tv-seek-slider'),
                                    min: 0,
                                    max: widget.duration > Duration.zero
                                        ? widget.duration.inMilliseconds
                                              .toDouble()
                                        : 1,
                                    value: (_scrubPosition ?? widget.position)
                                        .inMilliseconds
                                        .toDouble()
                                        .clamp(
                                          0,
                                          widget.duration > Duration.zero
                                              ? widget.duration.inMilliseconds
                                                    .toDouble()
                                              : 1,
                                        ),
                                    semanticFormatterCallback: (value) =>
                                        _clock(
                                          Duration(milliseconds: value.round()),
                                        ),
                                    onChangeStart:
                                        widget.duration > Duration.zero
                                        ? (value) {
                                            _timeline.requestFocus();
                                            _preview(value);
                                          }
                                        : null,
                                    onChanged: widget.duration > Duration.zero
                                        ? _preview
                                        : null,
                                    onChangeEnd: widget.duration > Duration.zero
                                        ? (_) => _commitScrub()
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              _clock(widget.duration),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                        Text(
                          _scrubPosition == null
                              ? 'Timeline: left / right to choose a time'
                              : 'Seek to ${_clock(_scrubPosition!)} · Select to confirm · Back to cancel',
                          key: const ValueKey('tv-seek-hint'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: widget.duration > Duration.zero
                                  ? () => _seek(-10)
                                  : null,
                              icon: const Icon(Icons.replay_10),
                              label: const Text('Back 10s'),
                            ),
                            FilledButton.icon(
                              focusNode: _play,
                              autofocus: true,
                              onPressed: _toggle,
                              icon: Icon(
                                widget.playing ? Icons.pause : Icons.play_arrow,
                              ),
                              label: Text(widget.playing ? 'Pause' : 'Play'),
                            ),
                            OutlinedButton.icon(
                              onPressed: widget.duration > Duration.zero
                                  ? () => _seek(10)
                                  : null,
                              icon: const Icon(Icons.forward_10),
                              label: const Text('Forward 10s'),
                            ),
                            if (widget.onNext != null) ...[
                              OutlinedButton.icon(
                                onPressed: widget.onNext,
                                icon: const Icon(Icons.skip_next),
                                label: const Text('Next'),
                              ),
                            ],
                            if (widget.onTracks != null)
                              OutlinedButton.icon(
                                onPressed: _openTracks,
                                icon: const Icon(Icons.closed_caption_outlined),
                                label: const Text('Audio & Captions'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
