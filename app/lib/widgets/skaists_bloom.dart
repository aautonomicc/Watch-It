import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Canonical beehive-WELLness mark — skaists mandala geometry
/// (bnr-design @ cdee76a), wellness colorway. SVG is the brand
/// source; the PNG sibling is what Flutter paints. Never put a
/// wordmark on the mandala; [BrandWordmark] stays separate.
const kSkaistsBloomSvgAsset = 'assets/skaists_bloom.svg';
const kSkaistsBloomMarkAsset = 'assets/skaists_bloom.png';

/// Three moments the skaists bloom is allowed to breathe.
///
/// New bee: [idle] — a few soft breaths after arrival, then rest.
/// Raver: [celebrate] — pulse from arrival and on Hold.
/// Cypherpunk: [still] at rest, [flash] once on a successful verify.
enum SkaistsBloomMoment { idle, celebrate, flash, still }

/// Wellness mandala with a finite breath. Repeating controllers
/// would hang `pumpAndSettle`.
class SkaistsBloom extends StatefulWidget {
  const SkaistsBloom({
    super.key,
    required this.moment,
    this.size = 56,
  });

  final SkaistsBloomMoment moment;
  final double size;

  @override
  State<SkaistsBloom> createState() => _SkaistsBloomState();
}

class _SkaistsBloomState extends State<SkaistsBloom>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _curve = const AlwaysStoppedAnimation(0.55);
    _arm(widget.moment);
  }

  @override
  void didUpdateWidget(SkaistsBloom old) {
    super.didUpdateWidget(old);
    if (old.moment != widget.moment) _arm(widget.moment);
  }

  void _arm(SkaistsBloomMoment moment) {
    _controller.stop();
    switch (moment) {
      case SkaistsBloomMoment.still:
        _curve = const AlwaysStoppedAnimation(0.72);
        _controller.value = 0;
      case SkaistsBloomMoment.idle:
        // Two soft breaths after arrival / Keep, then rest.
        _controller.duration = const Duration(milliseconds: 900);
        _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
        _runBreaths(1);
      case SkaistsBloomMoment.celebrate:
        _controller.duration = const Duration(milliseconds: 240);
        _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
        _runBreaths(2);
      case SkaistsBloomMoment.flash:
        _controller.duration = const Duration(milliseconds: 180);
        _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
        _controller.forward(from: 0);
    }
  }

  Future<void> _runBreaths(int count) async {
    for (var i = 0; i < count; i++) {
      if (!mounted) return;
      await _controller.forward(from: 0);
      if (!mounted) return;
      await _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: 'skaists bloom ${widget.moment.name}',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: reduce
            ? const _BloomMark(t: 0.55, glow: 0.35)
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = widget.moment == SkaistsBloomMoment.still
                      ? 0.72
                      : _curve.value;
                  final glow = widget.moment == SkaistsBloomMoment.celebrate
                      ? 0.28 + 0.55 * t
                      : 0.22 + 0.28 * t;
                  return _BloomMark(t: t, glow: glow);
                },
              ),
      ),
    );
  }
}

class _BloomMark extends StatelessWidget {
  const _BloomMark({required this.t, required this.glow});

  final double t;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final scale = 0.92 + 0.10 * t;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _WellnessGlowPainter(t: t, glow: glow)),
        Transform.scale(
          scale: scale,
          child: Image.asset(
            kSkaistsBloomMarkAsset,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => CustomPaint(
              painter: _WellnessGlowPainter(t: t, glow: glow, fill: true),
            ),
          ),
        ),
      ],
    );
  }
}

class _WellnessGlowPainter extends CustomPainter {
  _WellnessGlowPainter({
    required this.t,
    required this.glow,
    this.fill = false,
  });

  final double t;
  final double glow;
  final bool fill;

  Color get _color {
    if (t < 1 / 3) {
      return Color.lerp(WiTokens.bloomCore, WiTokens.bloomBlue, t * 3)!;
    }
    if (t < 2 / 3) {
      return Color.lerp(
          WiTokens.bloomBlue, WiTokens.bloomTeal, (t - 1 / 3) * 3)!;
    }
    return Color.lerp(WiTokens.bloomTeal, WiTokens.bloomRim, (t - 2 / 3) * 3)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final color = _color;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      c,
      size.shortestSide * 0.46,
      Paint()
        ..color = color.withValues(alpha: glow * 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 6 * glow),
    );
    if (fill) {
      canvas.drawCircle(
        c,
        size.shortestSide * 0.34,
        Paint()..color = color.withValues(alpha: 0.92),
      );
    }
  }

  @override
  bool shouldRepaint(_WellnessGlowPainter old) =>
      old.t != t || old.glow != glow || old.fill != fill;
}
