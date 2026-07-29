import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The launcher icon's popcorn-bucket mark (branding/icon.svg): three tapered
/// stripes — bone, red, bone — drawn on a transparent background so it sits on
/// whatever chrome hosts it. Geometry mirrors the SVG's 256x240 content box.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.height = 16});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return CustomPaint(
      size: Size(height * 256 / 240, height),
      painter: _BucketPainter(stripe: t.bone, center: WiTokens.bucketRed),
    );
  }
}

class _BucketPainter extends CustomPainter {
  const _BucketPainter({required this.stripe, required this.center});

  final Color stripe;
  final Color center;

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
    final sy = size.height / 240;
    for (var i = 0; i < _quads.length; i++) {
      final q = _quads[i];
      final path = Path()
        ..moveTo(q[0] * sx, 0)
        ..lineTo(q[1] * sx, 0)
        ..lineTo(q[2] * sx, 240 * sy)
        ..lineTo(q[3] * sx, 240 * sy)
        ..close();
      canvas.drawPath(path, Paint()..color = i == 1 ? center : stripe);
    }
  }

  @override
  bool shouldRepaint(_BucketPainter old) =>
      old.stripe != stripe || old.center != center;
}
