import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/poster_crop_dialog.dart';

/// A solid-colour PNG — image codec work needs tester.runAsync.
Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF3355AA));
  final img = await recorder.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('crop math', () {
    const image = Size(640, 480);
    const box = Size(200, 300);
    // Cover scale: height binds — 300/480.
    const eff = 300 / 480;

    test('coverBaseScale picks the covering dimension', () {
      expect(coverBaseScale(image: image, box: box), eff);
      expect(coverBaseScale(image: const Size(100, 900), box: box), 2.0);
    });

    test('default crop is the centered cover region', () {
      final src =
          cropSourceRect(image: image, box: box, zoom: 1, offset: Offset.zero);
      expect(src.width, closeTo(320, 0.001));
      expect(src.height, closeTo(480, 0.001));
      expect(src.center, const Offset(320, 240));
    });

    test('zoom narrows the source rect around the center', () {
      final src =
          cropSourceRect(image: image, box: box, zoom: 2, offset: Offset.zero);
      expect(src.width, closeTo(160, 0.001));
      expect(src.height, closeTo(240, 0.001));
      expect(src.center, const Offset(320, 240));
    });

    test('pan shifts the source rect the opposite way', () {
      final src = cropSourceRect(
          image: image, box: box, zoom: 1, offset: const Offset(50, 0));
      expect(src.center.dx, closeTo(320 - 50 / eff, 0.001));
      expect(src.center.dy, 240);
    });

    test('clampPan keeps the box covered at every edge', () {
      // At zoom 1 the display is 400x300 over a 200x300 box: 100px of
      // horizontal slack, none vertical.
      expect(
          clampPan(
              image: image, box: box, zoom: 1, offset: const Offset(500, 40)),
          const Offset(100, 0));
      expect(
          clampPan(
              image: image, box: box, zoom: 1, offset: const Offset(-500, -40)),
          const Offset(-100, 0));
      // Zoomed in there is slack both ways.
      final clamped = clampPan(
          image: image, box: box, zoom: 2, offset: const Offset(-9999, 9999));
      expect(clamped.dx, closeTo(-(640 * eff * 2 - 200) / 2, 0.001));
      expect(clamped.dy, closeTo((480 * eff * 2 - 300) / 2, 0.001));
      // A clamped pan never lets cropSourceRect escape the image.
      final src = cropSourceRect(
          image: image, box: box, zoom: 2, offset: clamped);
      expect(src.left, greaterThanOrEqualTo(-0.001));
      expect(src.top, greaterThanOrEqualTo(-0.001));
      expect(src.right, lessThanOrEqualTo(image.width + 0.001));
      expect(src.bottom, lessThanOrEqualTo(image.height + 0.001));
    });
  });

  group('PosterCropDialog', () {
    // Pumps a page whose button opens the dialog, opens it, and waits
    // for the image decode; the returned inner future is the dialog's
    // eventual result.
    Future<Future<Uint8List?>> pumpAndOpen(
        WidgetTester tester, Uint8List bytes) async {
      Future<Uint8List?>? result;
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => result = showDialog<Uint8List>(
                context: context,
                builder: (_) => PosterCropDialog(bytes: bytes),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      // decodeImageFromList is real async — let it finish.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      return result!;
    }

    testWidgets('default selection is the centered poster-aspect crop '
        'at natural resolution', (tester) async {
      final bytes = (await tester.runAsync(() => _png(640, 480)))!;
      final pending = await pumpAndOpen(tester, bytes);
      expect(find.text('Crop for poster'), findsOneWidget);
      await tester.tap(find.text('Use selection'));
      // Picture.toImage/toByteData are real async too.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final result = await pending;
      expect(result, isNotNull);
      final out = (await tester.runAsync(() => decodeImageFromList(result!)))!;
      // 480-high source, 2:3 box → centered 320x480 crop, no upscaling.
      expect(out.width, 320);
      expect(out.height, 480);
    });

    testWidgets('Use whole frame returns the original bytes',
        (tester) async {
      final bytes = (await tester.runAsync(() => _png(64, 48)))!;
      final pending = await pumpAndOpen(tester, bytes);
      await tester.tap(find.text('Use whole frame'));
      await tester.pumpAndSettle();
      expect(await pending, same(bytes));
    });

    testWidgets('Cancel returns nothing', (tester) async {
      final bytes = (await tester.runAsync(() => _png(64, 48)))!;
      final pending = await pumpAndOpen(tester, bytes);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await pending, isNull);
    });
  });
}
