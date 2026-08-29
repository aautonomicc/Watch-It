import 'dart:io';

import 'package:flutter/material.dart';

import '../services/channel_service.dart';
import '../theme/tokens.dart';

/// Circular channel avatar — THE channel-identity idiom (docs/
/// UI-DESIGN.md): circles mean channel identity, rectangles mean media;
/// this is the only circular artwork in the app. Renders the avatar
/// image clipped to a circle, or the podcasts icon on an amber-tinted
/// circle when the channel has none (older manifests, file not on disk
/// yet, or simply no avatar set).
///
/// Give it either a [file] directly (the owner's local crop) or a
/// manifest [memberName] to resolve through the posters directory.
class ChannelAvatar extends StatefulWidget {
  const ChannelAvatar({super.key, this.file, this.memberName, this.size = 40});

  final File? file;

  /// `channel_avatar_<sha8>.img`, as stored on the channel's list /
  /// subscription record; resolved via [ChannelService.avatarFileFor].
  final String? memberName;
  final double size;

  @override
  State<ChannelAvatar> createState() => _ChannelAvatarState();
}

class _ChannelAvatarState extends State<ChannelAvatar> {
  File? _resolved;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ChannelAvatar old) {
    super.didUpdateWidget(old);
    if (old.memberName != widget.memberName || old.file != widget.file) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (widget.file != null) {
      setState(() => _resolved = widget.file);
      return;
    }
    final file =
        await ChannelService.instance.avatarFileFor(widget.memberName);
    if (mounted) setState(() => _resolved = file);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final file = _resolved;
    if (file != null && file.existsSync()) {
      return ClipOval(
        child: Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallback(size),
        ),
      );
    }
    return _fallback(size);
  }

  Widget _fallback(double size) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0x26FFB300), // channelAmber, dimmed
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.podcasts,
            color: WiTokens.channelAmber, size: size * 0.55),
      );
}
