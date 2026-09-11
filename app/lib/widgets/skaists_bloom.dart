import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Three moments the skaists bloom is allowed to breathe.
///
/// New bee: [idle] — a few soft breaths after arrival, then rest.
/// Raver: [celebrate] — a short pulse when the piece is real / Keep.
/// Cypherpunk: [still] at rest, [flash] once on a successful verify.
enum SkaistsBloomMoment { idle, celebrate, flash, still }

/// Beehive-nature bloom: seven hex cells, green/yellow → purple.
/// Finite tickers only — repeating controllers would hang `pumpAndSettle`.
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
        // Two soft breaths, then rest on purple-ward mid.
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
            ? CustomPaint(
                painter: _BloomPainter(t: 0.55, glow: 0.35),
              )
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = widget.moment == SkaistsBloomMoment.still
                      ? 0.72
                      : _curve.value;
                  final glow = widget.moment == SkaistsBloomMoment.celebrate
                      ? 0.28 + 0.55 * t
                      : 0.22 + 0.28 * t;
                  return CustomPaint(painter: _BloomPainter(t: t, glow: glow));
                },
              ),
      ),
    );
  }
}

class _BloomPainter extends CustomPainter {
  _BloomPainter({required this.t, required this.glow});

  final double t;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final color = t < 0.5
        ? Color.lerp(WiTokens.bloomGreen, WiTokens.bloomYellow, t * 2)!
        : Color.lerp(WiTokens.bloomYellow, WiTokens.bloomPurple, (t - 0.5) * 2)!;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.shortestSide * (0.14 + 0.04 * t);

    canvas.drawCircle(
      Offset(cx, cy),
      size.shortestSide * 0.46,
      Paint()
        ..color = color.withValues(alpha: glow * 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 6 * glow),
    );

    // Centre cell, then six around it — a small hive.
    _hex(canvas, Offset(cx, cy), r * 1.08, color, 0.95);
    for (var i = 0; i < 6; i++) {
      final a = (i / 6) * math.pi * 2 - math.pi / 6;
      final dist = r * 1.95;
      final phase = ((t + i / 6) % 1.0);
      _hex(
        canvas,
        Offset(cx + math.cos(a) * dist, cy + math.sin(a) * dist),
        r * (0.72 + 0.1 * phase),
        color,
        0.55 + 0.35 * phase,
      );
    }
  }

  void _hex(Canvas canvas, Offset c, double r, Color color, double alpha) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final a = (i / 6) * math.pi * 2 - math.pi / 6;
      final p = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: math.min(1, alpha + 0.15))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(_BloomPainter old) => old.t != t || old.glow != glow;
}
