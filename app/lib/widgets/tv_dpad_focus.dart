import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tv_settings.dart';

/// On TV a freshly opened screen leaves focus on the route's scope: no
/// real node is focused, TvFocusFrame paints nothing, and the first
/// D-pad press hunts in from a screen edge — the tester's "you have to
/// press up/down to find where you are". Wrap a screen's Scaffold: once
/// the first frame is up, if nothing inside the scope took focus, the
/// scope's first traversal candidate gets it so the ring is visible from
/// the start. An explicit `autofocus` anywhere on the screen always wins
/// (it runs during that first frame, so this wrapper sees it and backs
/// off). Does nothing off TV.
class TvInitialFocus extends StatefulWidget {
  const TvInitialFocus({super.key, required this.child});

  final Widget child;

  @override
  State<TvInitialFocus> createState() => _TvInitialFocusState();
}

class _TvInitialFocusState extends State<TvInitialFocus> {
  @override
  void initState() {
    super.initState();
    if (!TvSettings.instance.enabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A pending `autofocus` from this frame is only applied in a later
      // microtask — flush it first so it wins over the wrapper.
      FocusManager.instance.applyFocusChangesIfNeeded();
      final scope = FocusScope.of(context);
      if (scope.focusedChild != null) return; // an autofocus beat us
      scope.nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Focus node for a dialog TextField that must not trap the D-pad.
///
/// A focused Flutter TextField consumes ALL FOUR arrow keys as caret
/// movement (the default text-editing shortcuts always handle them, and
/// DirectionalFocusAction.forTextField is a no-op), so on a TV remote
/// focus that entered a field could never leave by arrows — the invite
/// dialog trapped the remote below the Join button (tester report). On
/// TV this node turns vertical arrows into normal focus traversal, the
/// WiSeekSlider escape pattern; left/right stay caret movement (harmless
/// within one line). Off TV it is a plain FocusNode, so desktop keyboard
/// editing is untouched.
class TvFieldFocusNode extends FocusNode {
  TvFieldFocusNode({super.debugLabel}) : super(onKeyEvent: _escapeVertical);

  static KeyEventResult _escapeVertical(FocusNode node, KeyEvent event) {
    if (!TvSettings.instance.enabled) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    TraversalDirection? direction;
    if (key == LogicalKeyboardKey.arrowUp) direction = TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) {
      direction = TraversalDirection.down;
    }
    if (direction == null) return KeyEventResult.ignored;
    node.focusInDirection(direction);
    // Handled either way: a vertical arrow must never be swallowed as
    // caret movement, even when there is nothing to focus that way.
    return KeyEventResult.handled;
  }
}
