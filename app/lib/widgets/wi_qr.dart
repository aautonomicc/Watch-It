import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Brand-styled QR code: blue modules on the white card with the W@tch
/// logo centred (assets/qr_logo.png — the bucket icon on a rounded tile
/// with a white margin so it never touches a module).
///
/// Error correction is level H so the ~20% logo overlay stays scannable.
class WiQr extends StatelessWidget {
  const WiQr({super.key, required this.data, required this.size});

  final String data;
  final double size;

  /// Darker shade of the brand blue (== WiTokens.light.accent). The
  /// icon-stripe bucketBlue #42A5F5 is too light against white for
  /// reliable scanning (~2.6:1 contrast); this keeps ~4.6:1.
  static const moduleBlue = Color(0xFF1976D2);

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      data: data,
      version: QrVersions.auto,
      size: size,
      errorCorrectionLevel: QrErrorCorrectLevel.H,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: moduleBlue,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: moduleBlue,
      ),
      embeddedImage: const AssetImage('assets/qr_logo.png'),
      embeddedImageStyle: QrEmbeddedImageStyle(size: Size.square(size * 0.2)),
    );
  }
}
