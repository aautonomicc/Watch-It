import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/tv_app_frame.dart';
import 'package:watchit/widgets/device_name_dialog.dart';
import 'package:watchit/widgets/tv_player_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TvSettings.instance = TvSettings(enabled: true);
  });
  tearDown(() {
    TvSettings.instance.dispose();
    TvSettings.instance = TvSettings();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TvSettings.channel, null);
  });

  Widget app(Widget child, {bool frame = true}) => MaterialApp(
    theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
    builder: frame ? (context, child) => TvAppFrame(child: child!) : null,
    home: child,
  );

  testWidgets(
    'native TV detection loads bounded device settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'tv_margin_percent_v1': 30,
        'tv_grove_v1': true,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TvSettings.channel, (call) async => true);
      final tv = TvSettings();
      await tv.initialize();
      expect(tv.enabled, isTrue);
      expect(tv.marginPercent, 10);
      expect(tv.grove, isTrue);
      await tv.setMargin(-8);
      expect(tv.marginPercent, 0);
      expect(
        (await SharedPreferences.getInstance()).getInt('tv_margin_percent_v1'),
        0,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android phone keeps TV mode off',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TvSettings.channel, (call) async => false);
      final tv = TvSettings();
      await tv.initialize();
      expect(tv.enabled, isFalse);
      TvSettings.instance.enabled = false;
      await tester.pumpWidget(app(const Scaffold(body: Text('Phone'))));
      expect(find.byKey(const ValueKey('tv-safe-area')), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'missing native capability does not turn a phone into a TV',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            TvSettings.channel,
            (call) async => throw MissingPluginException(),
          );
      final tv = TvSettings();
      await tv.initialize();
      expect(tv.enabled, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'safe area encloses pushed dialogs and gives initial Continue focus',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const DeviceNameDialog(
                      title: 'Name this device',
                      initialName: 'Living room',
                    ),
                  );
                },
                child: const Text('Create'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final pad =
          tester
                  .widget<Padding>(find.byKey(const ValueKey('tv-safe-area')))
                  .padding
              as EdgeInsets;
      expect(pad.left, 40); // 5% of this test viewport's 800 logical pixels.
      expect(pad.top, 30);
      expect(find.byKey(const ValueKey('tv-focus-ring')), findsOneWidget);
      expect(
        tester.getRect(find.byType(AlertDialog)).left,
        greaterThanOrEqualTo(pad.left),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(result, 'Living room');
      expect(find.byType(AlertDialog), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'remote can move from Continue to Cancel without submitting',
    (tester) async {
      String? result = 'pending';
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const DeviceNameDialog(
                      title: 'Name this device',
                      initialName: 'TV',
                    ),
                  );
                },
                child: const Text('Create'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'name dialog refuses whitespace and phone keyboard Done submits',
    (tester) async {
      TvSettings.instance.enabled = false;
      String? result;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const DeviceNameDialog(
                      title: 'Name this device',
                      initialName: 'Phone',
                    ),
                  );
                },
                child: const Text('Create'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNull);
      await tester.enterText(find.byType(TextField), ' Samsung A16 ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(result, 'Samsung A16');
    },
  );

  testWidgets(
    'full bleed drops the frame padding while held and restores after',
    (tester) async {
      await tester.pumpWidget(app(const Scaffold(body: Text('TV'))));
      await tester.pumpAndSettle();
      EdgeInsets pad() =>
          tester
                  .widget<Padding>(find.byKey(const ValueKey('tv-safe-area')))
                  .padding
              as EdgeInsets;
      const framed = EdgeInsets.symmetric(horizontal: 40, vertical: 30);
      expect(pad(), framed);
      expect(TvSettings.instance.overscanInsets(const Size(800, 600)), framed);
      TvSettings.instance.pushFullBleed();
      await tester.pump();
      expect(pad(), EdgeInsets.zero);
      // The frame's chrome survives full bleed — only the padding goes.
      expect(find.byKey(const ValueKey('tv-safe-area')), findsOneWidget);
      TvSettings.instance.popFullBleed();
      await tester.pump();
      expect(pad(), framed);
    },
  );

  testWidgets(
    'player controls inset while the video child stays full-bleed',
    (tester) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: TvPlayerControls(
              title: 'Movie',
              position: Duration.zero,
              duration: const Duration(seconds: 20),
              playing: false,
              onPlayPause: () {},
              onSeek: (_) {},
              onExit: () {},
              inset: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
              child: const ColoredBox(
                key: ValueKey('video-surface'),
                color: Colors.black,
              ),
            ),
          ),
          frame: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('video-surface'))),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      final transport = tester.getRect(
        find.byKey(const ValueKey('tv-transport')),
      );
      expect(transport.left, 40);
      expect(transport.right, 760);
      expect(transport.bottom, 570);
      expect(tester.getRect(find.text('Back to library')).top, greaterThan(30));
    },
  );

  Widget player({
    bool playing = false,
    Duration position = const Duration(seconds: 5),
    Duration duration = const Duration(seconds: 20),
    VoidCallback? play,
    ValueChanged<Duration>? seek,
    VoidCallback? exit,
    VoidCallback? next,
  }) => app(
    Scaffold(
      body: TvPlayerControls(
        title: 'Big Buck Bunny',
        position: position,
        duration: duration,
        playing: playing,
        onPlayPause: play ?? () {},
        onSeek: seek ?? (_) {},
        onExit: exit ?? () {},
        onNext: next,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );

  testWidgets(
    'D-pad Select activates play; arrows reach bounded seek',
    (tester) async {
      var plays = 0;
      Duration? sought;
      await tester.pumpWidget(
        player(play: () => plays++, seek: (value) => sought = value),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(plays, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(sought, Duration.zero);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'seek never exceeds duration and unknown duration disables seeking',
    (tester) async {
      Duration? sought;
      await tester.pumpWidget(
        player(
          position: const Duration(seconds: 18),
          seek: (value) => sought = value,
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pumpAndSettle();
      expect(sought, const Duration(seconds: 20));
      sought = null;
      await tester.pumpWidget(
        player(duration: Duration.zero, seek: (value) => sought = value),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      expect(sought, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Forward 10s'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'playing overlay hides, Select reveals it, media key works hidden',
    (tester) async {
      var plays = 0;
      await tester.pumpWidget(player(playing: true, play: () => plays++));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-transport')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-transport')), findsOneWidget);
      expect(plays, 0);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(plays, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Back first hides controls, second Back can leave the player', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: TvPlayerControls(
                      title: 'Movie',
                      position: Duration.zero,
                      duration: const Duration(seconds: 20),
                      playing: false,
                      onPlayPause: () {},
                      onSeek: (_) {},
                      onExit: () => Navigator.of(context).pop(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              child: const Text('Open movie'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open movie'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TvPlayerControls), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-transport')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TvPlayerControls), findsNothing);
    expect(find.text('Open movie'), findsOneWidget);
  });

  testWidgets('Next appears only with an adjacent item and activates once', (
    tester,
  ) async {
    var next = 0;
    await tester.pumpWidget(player());
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
    await tester.pumpWidget(player(next: () => next++));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.pumpAndSettle();
    expect(next, 1);
  });
}
