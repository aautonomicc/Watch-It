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
    required this.accent,
    required this.accentBright,
    required this.rust,
    required this.signalOk,
  });

  final Color ink;
  final Color ink2;
  final Color line;
  final Color bone;
  final Color boneDim;
  final Color ash;
  final Color accent;
  final Color accentBright;
  final Color rust;
  final Color signalOk;

  /// Center-stripe blue of the popcorn-bucket app icon (branding/icon.svg).
  /// Same hue as the dark-theme `accent` — fixed across themes.
  static const bucketBlue = Color(0xFF42A5F5);

  /// Channels accent. Every PUBLIC surface (the Channels screen, channel
  /// badges, channel rows) is amber; the private space stays blue —
  /// vocabulary and colour are the first safety wall between the two
  /// content spaces (docs/PLAN-personal-vs-channels.md Part 3).
  static const channelAmber = Color(0xFFFFB300);

  static const dark = WiTokens(
    ink: Color(0xFF0A0A0A),
    ink2: Color(0xFF141414),
    line: Color(0xFF222222),
    bone: Color(0xFFF5F2EB),
    boneDim: Color(0xFFD6CFC0),
    ash: Color(0xFF8A8A8A),
    accent: Color(0xFF42A5F5),
    accentBright: Color(0xFF64B5F6),
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
    accent: Color(0xFF42A5F5),
    accentBright: Color(0xFF64B5F6),
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
    accent: Color(0xFF1976D2),
    accentBright: Color(0xFF1565C0),
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
    Color? accent,
    Color? accentBright,
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
      accent: accent ?? this.accent,
      accentBright: accentBright ?? this.accentBright,
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
      accent: Color.lerp(accent, other.accent, t)!,
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      rust: Color.lerp(rust, other.rust, t)!,
      signalOk: Color.lerp(signalOk, other.signalOk, t)!,
    );
  }
}

/// The active colour-scheme choice (Settings → Appearance). Dark is the
/// default — the look the app has always shipped with; light and system
/// map onto [WiTokens.light] via MaterialApp's theme/darkTheme pair.
/// Loaded from [AppSettings.themeMode] in main() and flipped live by the
/// Settings picker.
final ValueNotifier<ThemeMode> wiThemeMode = ValueNotifier(ThemeMode.dark);

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
      seedColor: t.accent,
      brightness: brightness,
      surface: t.ink,
      primary: t.accent,
      error: t.rust,
    ),
    textTheme: Typography.material2021(platform: defaultTargetPlatform)
        .black
        .apply(bodyColor: t.bone, displayColor: t.bone),
    extensions: [t],
    useMaterial3: true,
  );
}
