import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/tv_app_frame.dart';
import 'package:watchit/widgets/tv_player_controls.dart';

void main() {
  setUp(() => TvSettings.instance = TvSettings(enabled: true));
  tearDown(() {
    TvSettings.instance.dispose();
    TvSettings.instance = TvSettings();
  });

  Widget player(
    ValueChanged<Duration> seek, {
    Duration position = const Duration(seconds: 30),
    Duration duration = const Duration(seconds: 120),
    VoidCallback? play,
  }) => MaterialApp(
    theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
    builder: (_, child) => TvAppFrame(child: child!),
    home: Scaffold(
      body: TvPlayerControls(
        title: 'Seek test',
        position: position,
        duration: duration,
        playing: true,
        onPlayPause: play ?? () {},
        onSeek: seek,
        onExit: () {},
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );

  testWidgets(
    'remote previews without seeking and Select commits once',
    (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(player(seeks.add));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.textContaining('Seek to 00:50'), findsOneWidget);
      expect(seeks, isEmpty);
      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const ValueKey('tv-transport')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(seeks, [const Duration(seconds: 50)]);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Back cancels a bounded preview and keeps controls visible',
    (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        player(seeks.add, position: const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.textContaining('Seek to 00:00'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(seeks, isEmpty);
      expect(find.textContaining('Seek to '), findsNothing);
      expect(find.byKey(const ValueKey('tv-transport')), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 5000);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'upper bound clamps and leaving the timeline abandons the preview',
    (tester) async {
      final seeks = <Duration>[];
      var plays = 0;
      await tester.pumpWidget(
        player(
          seeks.add,
          position: const Duration(seconds: 115),
          play: () => plays++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.textContaining('Seek to 02:00'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.textContaining('Seek to '), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(seeks, isEmpty);
      expect(plays, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('drag previews until release, then seeks once', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(player(seeks.add));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(Slider));
    final drag = await tester.startGesture(
      Offset(rect.left + rect.width * .25, rect.center.dy),
    );
    await drag.moveTo(Offset(rect.left + rect.width * .75, rect.center.dy));
    await tester.pump();
    expect(seeks, isEmpty);
    await drag.up();
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1));
    expect(seeks.single.inSeconds, inInclusiveRange(80, 100));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unknown duration disables drag seeking', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(player(seeks.add, duration: Duration.zero));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
