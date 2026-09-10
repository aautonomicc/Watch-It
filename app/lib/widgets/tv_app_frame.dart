import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tv_settings.dart';
import '../theme/tokens.dart';

/// Insets the entire Navigator, including dialogs, inside the TV safe area.
/// No dependence on display width: phones retain their original layout.
class TvAppFrame extends StatelessWidget {
  const TvAppFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tv = TvSettings.instance;
    if (!tv.enabled) return child;
    final size = MediaQuery.sizeOf(context);
    final fraction = tv.marginPercent / 100;
    final theme = Theme.of(context);
    final t = WiTokens.of(context);
    return ColoredBox(
      color: t.ink,
      child: Padding(
        key: const ValueKey('tv-safe-area'),
        padding: EdgeInsets.symmetric(
          horizontal: size.width * fraction,
          vertical: size.height * fraction,
        ),
        child: ClipRect(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: MediaQuery.textScalerOf(
                context,
              ).clamp(minScaleFactor: 1.15),
            ),
            child: Theme(
              data: theme.copyWith(
                visualDensity: VisualDensity.standard,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                focusColor: t.accent.withValues(alpha: .24),
                listTileTheme: theme.listTileTheme.copyWith(
                  minVerticalPadding: 16,
                ),
              ),
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.gameButtonA):
                      ActivateIntent(),
                },
                child: TvFocusFrame(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Foreground focus ring: unlike ink effects it stays visible over artwork,
/// filled buttons and list tiles. Follows focus and scrolling, without a ticker.
class TvFocusFrame extends StatefulWidget {
  const TvFocusFrame({super.key, required this.child});
  final Widget child;
  @override
  State<TvFocusFrame> createState() => _TvFocusFrameState();
}

class _TvFocusFrameState extends State<TvFocusFrame>
    with WidgetsBindingObserver {
  final _frame = GlobalKey();
  Rect? _rect;
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
    _measureLater();
  }

  void _focusChanged() {
    final node = FocusManager.instance.primaryFocus;
    if (node != null && node is! FocusScopeNode && node.context != null) {
      Scrollable.ensureVisible(
        node.context!,
        duration: const Duration(milliseconds: 140),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
    _measureLater();
  }

  @override
  void didChangeMetrics() => _measureLater();

  void _measureLater() {
    if (_queued || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final node = FocusManager.instance.primaryFocus;
      final target = node is FocusScopeNode
          ? null
          : node?.context?.findRenderObject();
      final frame = _frame.currentContext?.findRenderObject();
      Rect? next;
      if (target is RenderBox &&
          target.attached &&
          target.hasSize &&
          frame is RenderBox &&
          frame.hasSize) {
        next =
            frame.globalToLocal(target.localToGlobal(Offset.zero)) &
            target.size;
        // Page-wide shortcut nodes are not actionable controls.
        if (next.width > frame.size.width * .95 &&
            next.height > frame.size.height * .6) {
          next = null;
        } else {
          next = next.intersect(Offset.zero & frame.size);
          if (next.isEmpty) next = null;
        }
      }
      if (_rect != next) setState(() => _rect = next);
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _measureLater();
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _measureLater();
        return false;
      },
      child: Stack(
        key: _frame,
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_rect case final rect?)
            Positioned.fromRect(
              rect: rect.deflate(2),
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    key: const ValueKey('tv-focus-ring'),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: WiTokens.of(context).bone,
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: WiTokens.of(context).accent,
                          blurRadius: 3,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
