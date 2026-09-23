import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// The desktop player's keyboard map (UI-DESIGN §5: mpv-style — space,
/// ←/→, f, m, s, numbers = percent-seek, `?` = this list). Built as plain
/// callbacks so the map itself is unit-testable without a real player;
/// PlayerScreen supplies the actions and hands the map to the vendored
/// media_kit desktop controls via the theme's `keyboardShortcuts:` (which
/// REPLACES the stock bindings, so everything lives here).
class PlayerShortcutActions {
  const PlayerShortcutActions({
    required this.playOrPause,
    required this.play,
    required this.pause,
    required this.seekBy,
    required this.seekToFraction,
    required this.volumeBy,
    required this.toggleMute,
    required this.toggleFullscreen,
    required this.exitFullscreen,
    required this.showHelp,
    this.screenshot,
  });

  final VoidCallback playOrPause;
  final VoidCallback play;
  final VoidCallback pause;

  /// Seek relative to the current position (clamping is the action's job).
  final void Function(Duration delta) seekBy;

  /// Seek to a fraction of the duration (0.0–0.9 from the digit keys).
  final void Function(double fraction) seekToFraction;

  /// Adjust volume by [delta] percentage points (clamped by the action).
  final void Function(double delta) volumeBy;

  final VoidCallback toggleMute;
  final VoidCallback toggleFullscreen;
  final VoidCallback exitFullscreen;

  /// Opens the `?` shortcut sheet.
  final VoidCallback showHelp;

  /// "Use this frame as artwork" — null hides the binding (kid profiles,
  /// audio playback).
  final VoidCallback? screenshot;
}

/// Seek step for ←/→ and J/L — matches the app's on-screen ±10s skips.
const kPlayerSeekStep = Duration(seconds: 10);

/// Volume step for ↑/↓, in percentage points.
const double kPlayerVolumeStep = 5.0;

/// Builds the full desktop keyboard map from [actions].
Map<ShortcutActivator, VoidCallback> playerKeyboardShortcuts(
  PlayerShortcutActions actions,
) {
  final map = <ShortcutActivator, VoidCallback>{
    // Hardware media keys.
    const SingleActivator(LogicalKeyboardKey.mediaPlay): actions.play,
    const SingleActivator(LogicalKeyboardKey.mediaPause): actions.pause,
    const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
        actions.playOrPause,
    // Transport.
    const SingleActivator(LogicalKeyboardKey.space): actions.playOrPause,
    const SingleActivator(LogicalKeyboardKey.keyK): actions.playOrPause,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        actions.seekBy(-kPlayerSeekStep),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        actions.seekBy(kPlayerSeekStep),
    const SingleActivator(LogicalKeyboardKey.keyJ): () =>
        actions.seekBy(-kPlayerSeekStep),
    const SingleActivator(LogicalKeyboardKey.keyL): () =>
        actions.seekBy(kPlayerSeekStep),
    // Volume.
    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
        actions.volumeBy(kPlayerVolumeStep),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        actions.volumeBy(-kPlayerVolumeStep),
    const SingleActivator(LogicalKeyboardKey.keyM): actions.toggleMute,
    // Window.
    const SingleActivator(LogicalKeyboardKey.keyF): actions.toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.escape): actions.exitFullscreen,
    // Help.
    const CharacterActivator('?'): actions.showHelp,
  };
  final screenshot = actions.screenshot;
  if (screenshot != null) {
    map[const SingleActivator(LogicalKeyboardKey.keyS)] = screenshot;
  }
  // 0–9 (top row and numpad) seek to 0%…90%.
  const digits = [
    (LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0),
    (LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1),
    (LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2),
    (LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3),
    (LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4),
    (LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5),
    (LogicalKeyboardKey.digit6, LogicalKeyboardKey.numpad6),
    (LogicalKeyboardKey.digit7, LogicalKeyboardKey.numpad7),
    (LogicalKeyboardKey.digit8, LogicalKeyboardKey.numpad8),
    (LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad9),
  ];
  for (var i = 0; i < digits.length; i++) {
    final fraction = i / 10;
    map[SingleActivator(digits[i].$1)] = () =>
        actions.seekToFraction(fraction);
    map[SingleActivator(digits[i].$2)] = () =>
        actions.seekToFraction(fraction);
  }
  return map;
}

/// One row of the `?` help sheet. [screenshot] rows are filtered out when
/// the binding is hidden.
typedef PlayerShortcutHelpRow = ({String keys, String action});

/// The rows the help sheet shows, in display order.
const kPlayerShortcutHelp = <PlayerShortcutHelpRow>[
  (keys: 'Space · K', action: 'Play / pause'),
  (keys: '← · →', action: 'Back / forward 10 seconds'),
  (keys: 'J · L', action: 'Back / forward 10 seconds'),
  (keys: '0–9', action: 'Jump to 0%–90% of the file'),
  (keys: '↑ · ↓', action: 'Volume up / down'),
  (keys: 'M', action: 'Mute / unmute'),
  (keys: 'F', action: 'Toggle fullscreen'),
  (keys: 'Esc', action: 'Leave fullscreen'),
  (keys: 'S', action: 'Use this frame as artwork'),
  (keys: '?', action: 'Show this list'),
];

/// The `?` sheet: a compact list of the keyboard map. [showScreenshotRow]
/// mirrors whether the S binding exists (kid profiles hide it).
Future<void> showPlayerShortcutHelp(
  BuildContext context, {
  bool showScreenshotRow = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      final rows = kPlayerShortcutHelp
          .where((r) => showScreenshotRow || r.keys != 'S')
          .toList();
      return AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 96,
                        child: Text(
                          row.keys,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: t.accent,
                            fontFamily: wiMonoFamily,
                            fontFamilyFallback: wiMonoFallback,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          row.action,
                          style: TextStyle(fontSize: 13, color: t.bone),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
