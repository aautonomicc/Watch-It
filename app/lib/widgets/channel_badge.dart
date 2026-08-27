import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Small amber capsule marking a PUBLIC / CHANNEL surface. Amber is the
/// channels accent everywhere (the private space stays blue) — part of
/// the naming/colour safety wall between the two content spaces.
class ChannelBadge extends StatelessWidget {
  const ChannelBadge({super.key, this.text = 'CHANNEL'});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: WiTokens.channelAmber, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: WiTokens.channelAmber,
        ),
      ),
    );
  }
}
