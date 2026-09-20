import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/widgets/seek_slider.dart';

// A plain Material Slider maps all four arrow keys to value adjustment, so
// on a TV remote a focused seek bar traps the D-pad (Scot's report: up/down
// seek exactly like left/right and only the back button escapes the bar).
// WiSeekSlider keeps left/right seeking and turns up/down into traversal.
void main() {
  Widget harness({
    required FocusNode top,
    required FocusNode bottom,
    required ValueChanged<double> onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(focusNode: top, onPressed: () {}, child: const Text('T')),
          WiSeekSlider(value: 50, max: 100, onChanged: onChanged),
          TextButton(
            focusNode: bottom,
            onPressed: () {},
            child: const Text('B'),
          ),
        ],
      ),
    ),
  );

  testWidgets('left/right seek; up/down move focus off the bar', (
    tester,
  ) async {
    final top = FocusNode(debugLabel: 'top');
    final bottom = FocusNode(debugLabel: 'bottom');
    addTearDown(() {
      top.dispose();
      bottom.dispose();
    });
    final changes = <double>[];
    await tester.pumpWidget(
      harness(top: top, bottom: bottom, onChanged: changes.add),
    );
    top.requestFocus();
    await tester.pump();

    // D-pad down lands on the seek slider.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(top.hasPrimaryFocus, isFalse);
    expect(bottom.hasPrimaryFocus, isFalse);
    expect(changes, isEmpty);

    // Right seeks forward, left seeks back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes, hasLength(1));
    expect(changes.last, greaterThan(50));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(changes, hasLength(2));
    expect(changes.last, lessThan(50));

    // Down LEAVES the bar (previously it seeked back like left) and never
    // adjusts the position.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(bottom.hasPrimaryFocus, isTrue);
    expect(changes, hasLength(2));

    // Back up onto the slider, then up again leaves to the top button.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(bottom.hasPrimaryFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(top.hasPrimaryFocus, isTrue);
    expect(changes, hasLength(2));
  });

  testWidgets('vertical arrow with nowhere to go never seeks', (tester) async {
    final changes = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: WiSeekSlider(value: 50, max: 100, onChanged: changes.add),
          ),
        ),
      ),
    );
    final node = tester
        .widgetList<Focus>(
          find.descendant(
            of: find.byType(WiSeekSlider),
            matching: find.byType(Focus),
          ),
        )
        .map((f) => f.focusNode)
        .firstWhere((n) => n?.debugLabel == 'seek slider')!;
    node.requestFocus();
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(changes, isEmpty);
    // Still focused — the keys were swallowed, not passed to the slider.
    expect(node.hasPrimaryFocus, isTrue);
  });

  // The Google TV Streamer report (issue #11): the remote's media FF/RW
  // keys did nothing on audio surfaces unless the seek bar held focus.
  // AudioMediaKeys wraps a surface and handles them from any focus.
  group('AudioMediaKeys', () {
    Widget mediaHarness({
      required Duration position,
      required Duration duration,
      ValueChanged<Duration>? onSeek,
    }) => MaterialApp(
      home: Scaffold(
        body: AudioMediaKeys(
          position: position,
          duration: duration,
          onSeek: onSeek,
          child: Column(
            children: [
              TextButton(
                autofocus: true,
                onPressed: () {},
                child: const Text('Transport'),
              ),
              const Text('Track list'),
            ],
          ),
        ),
      ),
    );

    testWidgets('media FF/RW seek ±10 s from a non-slider focus', (
      tester,
    ) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        mediaHarness(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 3),
          onSeek: seeks.add,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();
      expect(seeks, [const Duration(seconds: 40)]);

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaRewind);
      await tester.pump();
      expect(seeks.last, const Duration(seconds: 20));
    });

    testWidgets('seeks clamp to the track bounds', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        mediaHarness(
          position: const Duration(seconds: 4),
          duration: const Duration(seconds: 9),
          onSeek: seeks.add,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaRewind);
      await tester.pump();
      expect(seeks.last, Duration.zero);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();
      expect(seeks.last, const Duration(seconds: 9));
    });

    testWidgets('null onSeek (nothing playing) ignores the keys', (
      tester,
    ) async {
      await tester.pumpWidget(
        mediaHarness(
          position: Duration.zero,
          duration: const Duration(minutes: 3),
          onSeek: null,
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump();
      // Nothing to assert beyond "no crash" — the handler must report
      // ignored so the event keeps bubbling.
      expect(find.text('Transport'), findsOneWidget);
    });
  });
}
