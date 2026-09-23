import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/player_shortcuts.dart';

// The desktop player's keyboard map (UI-DESIGN §5, mpv-style). The map
// REPLACES the vendored controls' stock bindings via the theme, so these
// tests pin that every documented key exists and dispatches the right
// action — driven through a real CallbackShortcuts widget with simulated
// key events, exactly how the controls consume the map.
void main() {
  late List<String> log;
  late PlayerShortcutActions actions;

  setUp(() {
    log = [];
    actions = PlayerShortcutActions(
      playOrPause: () => log.add('playOrPause'),
      play: () => log.add('play'),
      pause: () => log.add('pause'),
      seekBy: (d) => log.add('seekBy:${d.inSeconds}'),
      seekToFraction: (f) => log.add('seekTo:$f'),
      volumeBy: (d) => log.add('volume:$d'),
      toggleMute: () => log.add('mute'),
      toggleFullscreen: () => log.add('fullscreen'),
      exitFullscreen: () => log.add('exitFullscreen'),
      showHelp: () => log.add('help'),
      screenshot: () => log.add('screenshot'),
    );
  });

  Widget harness(Map<ShortcutActivator, VoidCallback> bindings) =>
      MaterialApp(
        home: CallbackShortcuts(
          bindings: bindings,
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      );

  testWidgets('keys dispatch: transport, volume, mute, digits, S', (
    tester,
  ) async {
    await tester.pumpWidget(harness(playerKeyboardShortcuts(actions)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad9);

    expect(log, [
      'playOrPause',
      'playOrPause',
      'seekBy:-10',
      'seekBy:10',
      'seekBy:-10',
      'seekBy:10',
      'volume:5.0',
      'volume:-5.0',
      'mute',
      'fullscreen',
      'exitFullscreen',
      'screenshot',
      'seekTo:0.0',
      'seekTo:0.3',
      'seekTo:0.9',
    ]);
  });

  testWidgets('? opens help; media keys map to play/pause', (tester) async {
    await tester.pumpWidget(harness(playerKeyboardShortcuts(actions)));
    await tester.pump();
    // `?` is a character binding (layout-independent CharacterActivator).
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.slash,
      character: '?',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    expect(log, ['help', 'play', 'pause', 'playOrPause']);
  });

  test('no screenshot action = no S binding (kid profiles)', () {
    final without = playerKeyboardShortcuts(
      PlayerShortcutActions(
        playOrPause: () {},
        play: () {},
        pause: () {},
        seekBy: (_) {},
        seekToFraction: (_) {},
        volumeBy: (_) {},
        toggleMute: () {},
        toggleFullscreen: () {},
        exitFullscreen: () {},
        showHelp: () {},
      ),
    );
    expect(
      without.containsKey(const SingleActivator(LogicalKeyboardKey.keyS)),
      isFalse,
    );
    expect(
      playerKeyboardShortcuts(actions)
          .containsKey(const SingleActivator(LogicalKeyboardKey.keyS)),
      isTrue,
    );
  });

  testWidgets('help sheet lists the map; S row follows the flag', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlayerShortcutHelp(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Mute / unmute'), findsOneWidget);
    expect(find.text('Jump to 0%–90% of the file'), findsOneWidget);
    expect(find.text('Use this frame as artwork'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);

    // Kid profiles hide the S binding — and its help row.
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showPlayerShortcutHelp(context, showScreenshotRow: false),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Use this frame as artwork'), findsNothing);
  });
}
