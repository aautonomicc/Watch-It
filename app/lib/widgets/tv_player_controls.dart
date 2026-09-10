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

  @override
  State<TvPlayerControls> createState() => _TvPlayerControlsState();
}

class _TvPlayerControlsState extends State<TvPlayerControls> {
  final _remote = FocusNode(
    debugLabel: 'TV player remote',
    skipTraversal: true,
  );
  final _play = FocusNode(debugLabel: 'TV play pause');
  Timer? _timer;
  bool _visible = true;

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
    if (_visible && widget.playing) {
      _timer = Timer(const Duration(seconds: 6), _hide);
    }
  }

  void _hide() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _visible = false);
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

  void _toggle() {
    widget.onPlayPause();
    _show();
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
      if (_visible) {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_visible,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _hide();
    },
    child: Focus(
      focusNode: _remote,
      onKeyEvent: _key,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_visible) ...[
            Align(
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
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                key: const ValueKey('tv-transport'),
                color: Colors.black87,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          _clock(widget.position),
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: widget.duration > Duration.zero
                                ? (widget.position.inMilliseconds /
                                          widget.duration.inMilliseconds)
                                      .clamp(0.0, 1.0)
                                : 0,
                            minHeight: 5,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          _clock(widget.duration),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
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
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
