import 'dart:io';

import 'package:flutter/material.dart';

import '../services/profiles.dart';

/// The built-in avatar choices: a coloured circle with a friendly icon.
/// Referenced from a profile's avatar field as `preset:<index>` —
/// drawn, not image assets, so they cost nothing and theme cleanly.
const List<(Color, IconData)> kProfileAvatarPresets = [
  (Color(0xFF1976D2), Icons.sentiment_satisfied_alt), // blue
  (Color(0xFFE53935), Icons.rocket_launch_outlined), // red
  (Color(0xFF43A047), Icons.forest_outlined), // green
  (Color(0xFFF9A825), Icons.wb_sunny_outlined), // amber
  (Color(0xFF8E24AA), Icons.auto_awesome), // purple
  (Color(0xFF00897B), Icons.sailing_outlined), // teal
  (Color(0xFFD81B60), Icons.favorite_outline), // pink
  (Color(0xFF5D4037), Icons.pets_outlined), // brown
  (Color(0xFF3949AB), Icons.sports_esports_outlined), // indigo
  (Color(0xFFF4511E), Icons.local_pizza_outlined), // deep orange
  (Color(0xFF00ACC1), Icons.beach_access_outlined), // cyan
  (Color(0xFF7CB342), Icons.emoji_nature_outlined), // light green
];

/// Circular profile avatar: a preset (coloured circle + icon), a
/// cropped image from file, or the profile's initial letter on a
/// neutral circle when neither is set.
class ProfileAvatar extends StatefulWidget {
  const ProfileAvatar({
    super.key,
    required this.name,
    this.avatar,
    this.size = 40,
  });

  final String name;

  /// `preset:<n>` or a `profile_avatar_…` posters-dir file name.
  final String? avatar;
  final double size;

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ProfileAvatar old) {
    super.didUpdateWidget(old);
    if (old.avatar != widget.avatar) _resolve();
  }

  Future<void> _resolve() async {
    final file = await ProfileStore.avatarFile(widget.avatar);
    if (mounted) setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final avatar = widget.avatar;
    if (avatar != null && avatar.startsWith('preset:')) {
      final i = int.tryParse(avatar.substring(7)) ?? 0;
      final (color, icon) =
          kProfileAvatarPresets[i % kProfileAvatarPresets.length];
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: size * 0.55),
      );
    }
    final file = _file;
    if (file != null && file.existsSync()) {
      return ClipOval(
        child: Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initial(size),
        ),
      );
    }
    return _initial(size);
  }

  Widget _initial(double size) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      color: Color(0xFF37474F),
      shape: BoxShape.circle,
    ),
    child: Center(
      child: Text(
        widget.name.isEmpty ? '?' : widget.name[0].toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.45,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
