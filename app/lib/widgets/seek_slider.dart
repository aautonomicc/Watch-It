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
  });

  final double value;
  final double max;
  final Color? activeColor;
  final Color? inactiveColor;
  final ValueChanged<double>? onChanged;

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
    value: widget.value,
    max: widget.max,
    activeColor: widget.activeColor,
    inactiveColor: widget.inactiveColor,
    onChanged: widget.onChanged,
  );
}
