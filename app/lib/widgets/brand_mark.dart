import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The launcher icon's popcorn-bucket mark (branding/icon.svg): three tapered
/// stripes — bone, blue, bone — drawn on a transparent background so it sits on
/// whatever chrome hosts it. Geometry mirrors the SVG's 256x240 content box.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.height = 16});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return CustomPaint(
      size: Size(height * 256 / 240, height),
      painter: _BucketPainter(
        stripe: t.bone,
        center: WiTokens.bucketBlue,
        feather: bucketFeatherFor(
          MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0,
        ),
      ),
    );
  }
}

/// Width (logical px) of the hand-drawn anti-aliasing band on the bucket's
/// diagonal edges: one DEVICE pixel, the coverage ramp a real rasterizer
/// would produce. Flutter's Impeller renderer (the Linux desktop default)
/// fills paths WITHOUT anti-aliasing when the GPU offers no MSAA, so the
/// stripes' slanted edges came out stair-stepped beside the smooth
/// atlas-rendered wordmark (Linux Mint report, 2026-11-08); the painter
/// feathers those edges itself so the mark reads the same on every renderer.
double bucketFeatherFor(double devicePixelRatio) =>
    1.0 / (devicePixelRatio <= 0 ? 1.0 : devicePixelRatio);

/// The "W@tch" wordmark: Anton (bundled, wordmark-only font — UI text stays
/// on system fonts) in bone with the `@` in the accent blue, mirroring the
/// bucket mark's centre stripe. [fontSize] fits the host chrome (home app
/// bar 36 beside a 32px mark — doubled 2026-10-16; profile picker heading
/// 26; Settings About tile 16).
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.fontSize = 18});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontFamily: 'Anton',
          fontSize: fontSize,
          color: t.bone,
          letterSpacing: 0.5,
        ),
        children: [
          const TextSpan(text: 'W'),
          TextSpan(text: '@', style: TextStyle(color: t.accent)),
          const TextSpan(text: 'tch'),
        ],
      ),
    );
  }
}

class _BucketPainter extends CustomPainter {
  const _BucketPainter({
    required this.stripe,
    required this.center,
    required this.feather,
  });

  final Color stripe;
  final Color center;

  /// Total width of the edge ramp (half inside the true edge, half out).
  final double feather;

  // Stripe quads from branding/icon.svg, offset to a 256x240 content box:
  // each is (topLeft, topRight, bottomRight, bottomLeft) in x.
  static const _quads = [
    [0.0, 51.2, 84.8, 56.0],
    [102.4, 153.6, 142.4, 113.6],
    [204.8, 256.0, 200.0, 171.2],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 256;
    final h = size.height;
    // Never let the ramps eat a whole stripe at tiny sizes.
    final f = feather.clamp(0.0, 40.0 * sx);
    final half = f / 2;
    for (var i = 0; i < _quads.length; i++) {
      final q = _quads[i];
      final color = i == 1 ? center : stripe;
      // The opaque core: both slanted edges pulled inwards by half the ramp.
      final lt = Offset(q[0] * sx + half, 0);
      final lb = Offset(q[3] * sx + half, h);
      final rt = Offset(q[1] * sx - half, 0);
      final rb = Offset(q[2] * sx - half, h);
      canvas.drawPath(
        Path()
          ..moveTo(lt.dx, lt.dy)
          ..lineTo(rt.dx, rt.dy)
          ..lineTo(rb.dx, rb.dy)
          ..lineTo(lb.dx, lb.dy)
          ..close(),
        Paint()..color = color,
      );
      if (f <= 0) continue;
      // Edge ramps: a band `f` wide straddling each slanted edge, filled with
      // a gradient from the colour on the core side to transparent on the
      // outside — the coverage a rasterizer's AA would have given the edge.
      _ramp(canvas, lt, lb, Offset(-f, 0), color);
      _ramp(canvas, rt, rb, Offset(f, 0), color);
    }
  }

  /// Fills the parallelogram between the line [innerTop]→[innerBottom] and
  /// its copy shifted by [shift], shading from [color] at the inner line to
  /// transparent at the outer one (the gradient runs along the edge normal,
  /// so it is constant along the band).
  static void _ramp(
    Canvas canvas,
    Offset innerTop,
    Offset innerBottom,
    Offset shift,
    Color color,
  ) {
    final d = innerBottom - innerTop;
    final len = d.distance;
    if (len == 0) return;
    // Unit normal pointing the way the band extends.
    var n = Offset(d.dy, -d.dx) / len;
    if (n.dx * shift.dx < 0) n = -n;
    final w = (shift.dx * n.dx).abs();
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        innerTop,
        innerTop + n * w,
        [color, color.withValues(alpha: 0)],
      );
    canvas.drawPath(
      Path()
        ..moveTo(innerTop.dx, innerTop.dy)
        ..lineTo(innerTop.dx + shift.dx, innerTop.dy)
        ..lineTo(innerBottom.dx + shift.dx, innerBottom.dy)
        ..lineTo(innerBottom.dx, innerBottom.dy)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_BucketPainter old) =>
      old.stripe != stripe || old.center != center || old.feather != feather;
}
