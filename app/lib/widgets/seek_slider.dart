import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Horizontal seek bar for the audio players.
///
/// A plain Material [Slider] maps ALL four arrow keys to value adjustment
/// (up/right = forward, down/left = back), so on a TV remote or keyboard a
/// focused seek bar traps the focus: every D-pad press seeks and nothing
/// moves the focus away (only Back escapes). This wrapper keeps left/right
/// as seeking and turns up/down into normal focus traversal so the
/// transport row / track list stay reachable.
class WiSeekSlider extends StatefulWidget {
  const WiSeekSlider({
    super.key,
    required this.value,
    required this.max,
    this.activeColor,
    this.inactiveColor,
    this.onChanged,
    this.autofocus = false,
  });

  final double value;
  final double max;
  final Color? activeColor;
  final Color? inactiveColor;
  final ValueChanged<double>? onChanged;

  /// The full-screen audio player sets this on TV so the remote's
  /// left/right seek immediately when the player opens, instead of
  /// doing nothing until focus happens to land on the bar (issue #11).
  final bool autofocus;

  @override
  State<WiSeekSlider> createState() => _WiSeekSliderState();
}

class _WiSeekSliderState extends State<WiSeekSlider> {
  late final FocusNode _focus = FocusNode(
    debugLabel: 'seek slider',
    onKeyEvent: _onKey,
  );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    TraversalDirection? direction;
    if (key == LogicalKeyboardKey.arrowUp) direction = TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) {
      direction = TraversalDirection.down;
    }
    if (direction == null) return KeyEventResult.ignored;
    node.focusInDirection(direction);
    // Handled either way: a vertical arrow must never adjust the seek
    // position, even when there is nothing to focus in that direction.
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Slider(
    focusNode: _focus,
    autofocus: widget.autofocus,
    value: widget.value,
    max: widget.max,
    activeColor: widget.activeColor,
    inactiveColor: widget.inactiveColor,
    onChanged: widget.onChanged,
  );
}

/// Handles the remote's media fast-forward/rewind keys for an audio
/// surface, whatever child currently holds focus.
///
/// [TvPlayerControls] maps these keys to ±10 s seeks for video, but the
/// audio surfaces render their own transports and the keys fell through
/// unhandled — on a TV remote seeking looked broken unless the seek bar
/// itself held focus (issue #11). Wrap the surface's body; key events
/// bubble up here from whichever descendant has focus.
class AudioMediaKeys extends StatelessWidget {
  const AudioMediaKeys({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.child,
  });

  final Duration position;
  final Duration duration;

  /// Absolute seek target; null while nothing is playing (keys ignored).
  final ValueChanged<Duration>? onSeek;
  final Widget child;

  /// Same step as the TV video overlay's media-key seek.
  static const step = Duration(seconds: 10);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final seek = onSeek;
    if (seek == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.mediaRewind &&
        key != LogicalKeyboardKey.mediaFastForward) {
      return KeyEventResult.ignored;
    }
    var target = key == LogicalKeyboardKey.mediaRewind
        ? position - step
        : position + step;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    seek(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: child,
  );
}
