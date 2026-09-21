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

/// Content width for a dialog holding a QR: the usual 300, widened on
/// short viewports (a TV is 960×540 logical) so the surrounding text
/// wraps into fewer lines and leaves the QR its scannable height.
double wiQrDialogWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).height < 560 ? 460 : 300;

/// The white QR card the share/pairing dialogs show, sized to the height
/// it is actually given: at [size] when there is room, shrinking down to
/// [minSize] on small dialog viewports (a TV at 960×540 logical minus
/// overscan margins leaves the dialog ~300px of content height — a fixed
/// 220px QR pushed its own bottom third out of view).
///
/// Callers put this inside a bounded column as `Flexible(child: …)`;
/// the [LayoutBuilder] then sees the free height left after the fixed
/// content. [minSize] keeps the code scannable — below ~120px a dense
/// pairing code stops reading reliably. On a viewport too small even
/// for the floor, the whole card scales down as one unit (modules,
/// margin and logo in proportion) instead of squeezing out of shape.
class WiQrCard extends StatelessWidget {
  const WiQrCard({
    super.key,
    required this.data,
    required this.size,
    this.minSize = 120,
  });

  final String data;

  /// Natural module size, used whenever the dialog has room for it.
  final double size;

  final double minSize;

  /// The white quiet-zone margin around the modules.
  static const padding = 8.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          var qr = size;
          if (constraints.maxHeight.isFinite) {
            qr = (constraints.maxHeight - 2 * padding).clamp(minSize, size);
          }
          return FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(padding),
              child: WiQr(data: data, size: qr),
            ),
          );
        },
      );
}
