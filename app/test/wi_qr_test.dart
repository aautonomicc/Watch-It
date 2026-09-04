import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:watchit/widgets/wi_qr.dart';

void main() {
  testWidgets('WiQr renders a brand-styled QR with the embedded logo',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: WiQr(data: 'wtch1-abc123', size: 200)),
    ));

    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.errorCorrectionLevel, QrErrorCorrectLevel.H,
        reason: 'logo overlay needs level H to stay scannable');
    expect(qr.eyeStyle.color, WiQr.moduleBlue);
    expect(qr.dataModuleStyle.color, WiQr.moduleBlue);
    expect(qr.embeddedImage, const AssetImage('assets/qr_logo.png'));
    expect(qr.embeddedImageStyle?.size, const Size.square(40));
  });
}
