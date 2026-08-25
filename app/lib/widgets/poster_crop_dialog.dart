import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Poster artwork aspect (width : height) — matches TMDB posters and the
/// app's poster tiles/preview (120x180).
const double kPosterAspect = 2 / 3;

/// Minimum scale at which [image] fully covers [box] (BoxFit.cover).
double coverBaseScale({required Size image, required Size box}) =>
    math.max(box.width / image.width, box.height / image.height);

/// Clamp a pan offset so the image (at [zoom] × cover scale) still
/// covers the crop box — no gaps at any edge.
Offset clampPan({
  required Size image,
  required Size box,
  required double zoom,
  required Offset offset,
}) {
  final eff = coverBaseScale(image: image, box: box) * zoom;
  final maxX = math.max(0.0, (image.width * eff - box.width) / 2);
  final maxY = math.max(0.0, (image.height * eff - box.height) / 2);
  return Offset(
      offset.dx.clamp(-maxX, maxX), offset.dy.clamp(-maxY, maxY));
}

/// The region of the source image (in image pixels) the crop box shows
/// for a given zoom/pan. At zoom 1 / zero offset this is the centered
/// BoxFit.cover region.
Rect cropSourceRect({
  required Size image,
  required Size box,
  required double zoom,
  required Offset offset,
}) {
  final eff = coverBaseScale(image: image, box: box) * zoom;
  final cx = image.width / 2 - offset.dx / eff;
  final cy = image.height / 2 - offset.dy / eff;
  return Rect.fromCenter(
      center: Offset(cx, cy),
      width: box.width / eff,
      height: box.height / eff);
}

/// Crop/zoom step after a frame (or image) is picked as artwork: a
/// fixed poster-aspect selector box sits over the image; drag to move
/// the shot under it, pinch/scroll/slider to zoom in on the part that
/// should become the poster. Pops the cropped bytes (PNG at the crop's
/// natural resolution, never upscaled), the untouched original via
/// "Use whole frame", or null on cancel.
class PosterCropDialog extends StatefulWidget {
  const PosterCropDialog({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<PosterCropDialog> createState() => _PosterCropDialogState();
}

class _PosterCropDialogState extends State<PosterCropDialog> {
  static const Size _viewport = Size(520, 360);
  static const double _maxZoom = 5;

  ui.Image? _image;
  String? _decodeError;
  double _zoom = 1;
  Offset _offset = Offset.zero;
  bool _busy = false;

  // Gesture-start snapshot (scale gestures report cumulative factors).
  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// Largest poster-aspect box that fits the viewport with a margin.
  Size get _box {
    final h = math.min(
        _viewport.height - 16, (_viewport.width - 16) / kPosterAspect);
    return Size(h * kPosterAspect, h);
  }

  Size get _imageSize =>
      Size(_image!.width.toDouble(), _image!.height.toDouble());

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.bytes).then((img) {
      if (mounted) setState(() => _image = img);
    }, onError: (Object e) {
      if (mounted) {
        setState(() => _decodeError = 'Could not read that image.');
      }
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _setZoom(double zoom, {Offset? pan}) {
    _zoom = zoom.clamp(1.0, _maxZoom);
    _offset = clampPan(
        image: _imageSize, box: _box, zoom: _zoom, offset: pan ?? _offset);
  }

  Future<void> _useSelection() async {
    final img = _image;
    if (img == null || _busy) return;
    setState(() => _busy = true);
    final src = cropSourceRect(
        image: _imageSize, box: _box, zoom: _zoom, offset: _offset);
    // Natural resolution of the selected region — zooming in narrows the
    // source rect, it never upscales pixels.
    final outW = src.width.round().clamp(1, img.width);
    final outH = src.height.round().clamp(1, img.height);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      img,
      src,
      Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final out = await recorder.endRecording().toImage(outW, outH);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (!mounted) return;
    if (data == null) {
      setState(() => _busy = false);
      return;
    }
    Navigator.of(context).pop(data.buffer.asUint8List());
  }

  Widget _cropArea(WiTokens t) {
    final img = _image;
    if (img == null) {
      return SizedBox(
        width: _viewport.width,
        height: _viewport.height,
        child: Center(
          child: _decodeError != null
              ? Text(_decodeError!,
                  style: TextStyle(color: t.boneDim, fontSize: 12.5))
              : SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: t.accent)),
        ),
      );
    }
    final boxRect = Rect.fromCenter(
        center: _viewport.center(Offset.zero),
        width: _box.width,
        height: _box.height);
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        setState(
            () => _setZoom(_zoom * math.exp(-event.scrollDelta.dy / 400)));
      },
      child: GestureDetector(
        onScaleStart: (d) {
          _startZoom = _zoom;
          _startOffset = _offset;
          _startFocal = d.focalPoint;
        },
        onScaleUpdate: (d) => setState(() => _setZoom(
              _startZoom * d.scale,
              pan: _startOffset + (d.focalPoint - _startFocal),
            )),
        child: ClipRect(
          child: CustomPaint(
            size: _viewport,
            painter: _CropPainter(
              image: img,
              scale:
                  coverBaseScale(image: _imageSize, box: _box) * _zoom,
              offset: _offset,
              box: boxRect,
              borderColor: t.accent,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Crop for poster',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: _viewport.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The box is the poster: drag the image to position it, '
              'zoom to fill the box with the part you want.',
              style: TextStyle(color: t.boneDim, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            _cropArea(t),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.zoom_out, size: 18, color: t.ash),
              Expanded(
                child: Slider(
                  value: _zoom,
                  min: 1,
                  max: _maxZoom,
                  activeColor: t.accent,
                  inactiveColor: t.ink,
                  onChanged: _image == null
                      ? null
                      : (v) => setState(() => _setZoom(v)),
                ),
              ),
              Icon(Icons.zoom_in, size: 18, color: t.ash),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _busy ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(widget.bytes),
          child: Text('Use whole frame',
              style: TextStyle(color: t.boneDim)),
        ),
        TextButton(
          onPressed: _image == null || _busy ? null : _useSelection,
          child: Text('Use selection',
              style: TextStyle(
                  color: t.accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.scale,
    required this.offset,
    required this.box,
    required this.borderColor,
  });

  final ui.Image image;
  final double scale;
  final Offset offset;
  final Rect box;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final dispW = image.width * scale;
    final dispH = image.height * scale;
    final topLeft = Offset(size.width / 2 + offset.dx - dispW / 2,
        size.height / 2 + offset.dy - dispH / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      topLeft & Size(dispW, dispH),
      Paint()..filterQuality = FilterQuality.medium,
    );
    // Dim everything outside the selector box, then outline it with
    // rule-of-thirds guides inside.
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(box)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = const Color(0x99000000));
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color(0x66FFFFFF);
    for (var i = 1; i <= 2; i++) {
      final x = box.left + box.width * i / 3;
      final y = box.top + box.height * i / 3;
      canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom), guide);
      canvas.drawLine(Offset(box.left, y), Offset(box.right, y), guide);
    }
    canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = borderColor);
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image ||
      old.scale != scale ||
      old.offset != offset ||
      old.box != box;
}
