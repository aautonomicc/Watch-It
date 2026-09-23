import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/window_state.dart';

// Desktop window polish: the remembered-geometry codec must round-trip
// and shrug off garbage (the pref survives app upgrades and hand edits),
// and restored sizes must never fall under the usable minimum.
void main() {
  test('encode/decode round trip', () {
    const data = WindowStateData(
      x: 120,
      y: 64,
      width: 1440,
      height: 900,
      maximized: true,
    );
    final back = WindowStateData.decode(data.encode())!;
    expect(back.x, 120);
    expect(back.y, 64);
    expect(back.width, 1440);
    expect(back.height, 900);
    expect(back.maximized, isTrue);
  });

  test('position is optional', () {
    const data = WindowStateData(width: 1280, height: 720);
    final back = WindowStateData.decode(data.encode())!;
    expect(back.sanitizedPosition, isNull);
    expect(back.maximized, isFalse);
  });

  test('garbage decodes to null (window opens at the runner default)', () {
    expect(WindowStateData.decode(null), isNull);
    expect(WindowStateData.decode(''), isNull);
    expect(WindowStateData.decode('not json'), isNull);
    expect(WindowStateData.decode('[1,2]'), isNull);
    expect(WindowStateData.decode('{"w":"wide"}'), isNull);
    expect(WindowStateData.decode('{"x":1,"y":2}'), isNull);
  });

  test('sanitized size never restores below the minimum', () {
    const tiny = WindowStateData(width: 100, height: 50);
    expect(tiny.sanitizedSize, kMinWindowSize);
    const nan = WindowStateData(width: double.nan, height: double.infinity);
    expect(nan.sanitizedSize, const Size(1280, 720));
    const fine = WindowStateData(width: 1440, height: 900);
    expect(fine.sanitizedSize, const Size(1440, 900));
  });

  test('absurd positions are dropped, sane ones kept', () {
    const offscreen = WindowStateData(x: 1e9, y: 0, width: 1280, height: 720);
    expect(offscreen.sanitizedPosition, isNull);
    const negative = WindowStateData(x: -8, y: -8, width: 1280, height: 720);
    expect(negative.sanitizedPosition, const Offset(-8, -8));
  });

  test('minimum stays under the pinned-drawer breakpoint', () {
    // Both home layouts (pinned panel ≥1000px, modal below) must stay
    // reachable by resizing — the minimum may not swallow the breakpoint.
    expect(kMinWindowSize.width, lessThan(1000));
  });
}
