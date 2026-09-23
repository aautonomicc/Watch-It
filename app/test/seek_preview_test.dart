import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:watchit/services/seek_preview.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/seek_preview_card.dart';

// Hover seek thumbnails (desktop, LOCAL files only — a streamed source
// pays a network prefetch window per frame grab, so PlayerScreen never
// builds a SeekPreview for one). These tests pin the cache/debounce
// behaviour with an injected extractor and the fork's clamped positioning.
void main() {
  Uint8List frame(int n) => Uint8List.fromList([n, n, n]);

  test('buckets fold nearby positions onto one frame', () {
    final preview = SeekPreview(source: 'x', extractor: (_) async => null);
    expect(preview.bucketFor(const Duration(seconds: 0)), 0);
    expect(preview.bucketFor(const Duration(seconds: 4)), 0);
    expect(preview.bucketFor(const Duration(seconds: 5)), 1);
    expect(preview.bucketFor(const Duration(seconds: 61)), 12);
    expect(preview.secondsFor(1), 7.5);
    preview.dispose();
  });

  testWidgets('debounced grab: one extract per bucket, then cached', (
    tester,
  ) async {
    final asked = <double>[];
    final preview = SeekPreview(
      source: 'x',
      extractor: (s) async {
        asked.add(s);
        return frame(asked.length);
      },
    );
    // A sweep across one bucket schedules but doesn't fetch…
    expect(preview.frameFor(const Duration(seconds: 1)), isNull);
    expect(preview.frameFor(const Duration(seconds: 2)), isNull);
    await tester.pump(const Duration(milliseconds: 100));
    expect(asked, isEmpty);
    // …until the pointer rests past the debounce.
    await tester.pump(const Duration(milliseconds: 200));
    expect(asked, [2.5]);
    // Now cached — no further extraction for the same bucket.
    expect(preview.frameFor(const Duration(seconds: 3)), frame(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(asked, [2.5]);
    preview.dispose();
  });

  testWidgets('failed grabs are cached — a bad timestamp is never hammered',
      (tester) async {
    var calls = 0;
    final preview = SeekPreview(
      source: 'x',
      extractor: (_) async {
        calls++;
        return null;
      },
    );
    preview.frameFor(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1);
    expect(preview.frameFor(const Duration(seconds: 1)), isNull);
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, 1);
    preview.dispose();
  });

  testWidgets('a moved pointer is chased after the in-flight grab lands', (
    tester,
  ) async {
    final completers = <Completer<Uint8List?>>[];
    final asked = <double>[];
    final preview = SeekPreview(
      source: 'x',
      extractor: (s) {
        asked.add(s);
        final completer = Completer<Uint8List?>();
        completers.add(completer);
        return completer.future;
      },
    );
    preview.frameFor(const Duration(seconds: 1)); // bucket 0
    await tester.pump(const Duration(milliseconds: 200));
    expect(asked, [2.5]);
    // Pointer moved to bucket 4 while bucket 0 is still extracting.
    preview.frameFor(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 200));
    expect(asked, [2.5]); // Serialized: no concurrent grab.
    completers[0].complete(frame(1));
    await tester.pump();
    expect(asked, [2.5, 22.5]); // Chased the newest bucket.
    completers[1].complete(frame(2));
    await tester.pump();
    expect(preview.frameFor(const Duration(seconds: 22)), frame(2));
    preview.dispose();
  });

  testWidgets('LRU cap evicts the stalest buckets', (tester) async {
    final preview = SeekPreview(
      source: 'x',
      maxEntries: 2,
      debounce: const Duration(milliseconds: 10),
      extractor: (s) async => frame(s.toInt()),
    );
    for (final seconds in [1, 6, 11]) {
      preview.frameFor(Duration(seconds: seconds));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Bucket 0 evicted, 1 + 2 kept.
    expect(preview.frameFor(const Duration(seconds: 6)), isNotNull);
    expect(preview.frameFor(const Duration(seconds: 11)), isNotNull);
    expect(preview.frameFor(const Duration(seconds: 1)), isNull);
    preview.dispose();
  });

  testWidgets('card: timestamp-only until the frame lands, then thumbnail', (
    tester,
  ) async {
    final completer = Completer<Uint8List?>();
    final preview = SeekPreview(
      source: 'x',
      debounce: const Duration(milliseconds: 10),
      extractor: (_) => completer.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Center(
          child: SeekPreviewCard(
            preview: preview,
            position: const Duration(minutes: 75, seconds: 3),
          ),
        ),
      ),
    );
    // h:mm:ss timestamp always shows; no image yet.
    expect(find.text('1:15:03'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    // A real (decodable) 1x1 PNG so Image.memory renders.
    completer.complete(Uint8List.fromList(kTransparentImage));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    preview.dispose();
  });

  testWidgets('card without a preview source renders timestamp only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const Center(
          child: SeekPreviewCard(
            preview: null,
            position: Duration(minutes: 2, seconds: 5),
          ),
        ),
      ),
    );
    expect(find.text('2:05'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  test('fork delegate clamps the preview inside the bar', () {
    const size = Size(1000, 140);
    const child = Size(160, 100);
    Offset at(double x) => SeekBarPreviewLayoutDelegate(x: x)
        .getPositionForChild(size, child);
    expect(at(500), const Offset(420, 40)); // Centered, bottom-aligned.
    expect(at(0), const Offset(0, 40)); // Clamped left.
    expect(at(1000), const Offset(840, 40)); // Clamped right.
  });
}

/// Smallest valid transparent PNG (1×1) — enough for Image.memory.
const kTransparentImage = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
