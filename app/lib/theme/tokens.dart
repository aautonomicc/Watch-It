import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Brand tokens from docs/BRAND.md (etchit.io family contract).
/// No hex literals in UI code — everything goes through this extension.
@immutable
class WiTokens extends ThemeExtension<WiTokens> {
  const WiTokens({
    required this.ink,
    required this.ink2,
    required this.line,
    required this.bone,
    required this.boneDim,
    required this.ash,
    required this.copper,
    required this.copperBright,
    required this.rust,
    required this.signalOk,
  });

  final Color ink;
  final Color ink2;
  final Color line;
  final Color bone;
  final Color boneDim;
  final Color ash;
  final Color copper;
  final Color copperBright;
  final Color rust;
  final Color signalOk;

  /// Center-stripe red of the popcorn-bucket app icon (branding/icon.svg).
  /// Icon-only accent — fixed across themes, never used for UI chrome.
  static const bucketRed = Color(0xFFEF5350);

  static const dark = WiTokens(
    ink: Color(0xFF0A0A0A),
    ink2: Color(0xFF141414),
    line: Color(0xFF222222),
    bone: Color(0xFFF5F2EB),
    boneDim: Color(0xFFD6CFC0),
    ash: Color(0xFF8A8A8A),
    copper: Color(0xFFC9732B),
    copperBright: Color(0xFFE58A3F),
    rust: Color(0xFFFF8A7A),
    signalOk: Color(0xFF6AB04C),
  );

  static const dim = WiTokens(
    ink: Color(0xFF1A1612),
    ink2: Color(0xFF221D18),
    line: Color(0xFF2A2520),
    bone: Color(0xFFF5F2EB),
    boneDim: Color(0xFFE6DFD0),
    ash: Color(0xFFA09A90),
    copper: Color(0xFFC9732B),
    copperBright: Color(0xFFE58A3F),
    rust: Color(0xFFFF8A7A),
    signalOk: Color(0xFF6AB04C),
  );

  static const light = WiTokens(
    ink: Color(0xFFF5F2EB),
    ink2: Color(0xFFFAF7F2),
    line: Color(0xFFD6CFC0),
    bone: Color(0xFF0A0A0A),
    boneDim: Color(0xFF1A1814),
    ash: Color(0xFF3A3A3A),
    copper: Color(0xFFC9732B),
    copperBright: Color(0xFFB86420),
    rust: Color(0xFFC0392B),
    signalOk: Color(0xFF3D7E2C),
  );

  static WiTokens of(BuildContext context) =>
      Theme.of(context).extension<WiTokens>()!;

  @override
  WiTokens copyWith({
    Color? ink,
    Color? ink2,
    Color? line,
    Color? bone,
    Color? boneDim,
    Color? ash,
    Color? copper,
    Color? copperBright,
    Color? rust,
    Color? signalOk,
  }) {
    return WiTokens(
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      line: line ?? this.line,
      bone: bone ?? this.bone,
      boneDim: boneDim ?? this.boneDim,
      ash: ash ?? this.ash,
      copper: copper ?? this.copper,
      copperBright: copperBright ?? this.copperBright,
      rust: rust ?? this.rust,
      signalOk: signalOk ?? this.signalOk,
    );
  }

  @override
  WiTokens lerp(WiTokens? other, double t) {
    if (other == null) return this;
    return WiTokens(
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      line: Color.lerp(line, other.line, t)!,
      bone: Color.lerp(bone, other.bone, t)!,
      boneDim: Color.lerp(boneDim, other.boneDim, t)!,
      ash: Color.lerp(ash, other.ash, t)!,
      copper: Color.lerp(copper, other.copper, t)!,
      copperBright: Color.lerp(copperBright, other.copperBright, t)!,
      rust: Color.lerp(rust, other.rust, t)!,
      signalOk: Color.lerp(signalOk, other.signalOk, t)!,
    );
  }
}

/// Mono stack for the wordmark and XOR addresses (name-preference only,
/// nothing shipped — falls back to the platform mono).
const wiMonoFamily = 'JetBrains Mono';
const wiMonoFallback = ['Source Code Pro', 'Menlo', 'Consolas', 'monospace'];

ThemeData wiTheme(WiTokens t, {required Brightness brightness}) {
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: t.ink,
    canvasColor: t.ink,
    cardColor: t.ink2,
    dividerColor: t.line,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.copper,
      brightness: brightness,
      surface: t.ink,
      primary: t.copper,
      error: t.rust,
    ),
    textTheme: Typography.material2021(platform: defaultTargetPlatform)
        .black
        .apply(bodyColor: t.bone, displayColor: t.bone),
    extensions: [t],
    useMaterial3: true,
  );
}
