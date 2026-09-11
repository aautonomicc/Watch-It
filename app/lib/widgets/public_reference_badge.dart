import 'package:flutter/material.dart';

import '../services/experience_view.dart';
import '../theme/tokens.dart';

/// Provenance chip for a public / shared library item. Amber like other
/// public surfaces (channels stay CHANNEL; this says Shared / public XOR
/// by register) so New bees are not scared by "XOR" until they ask.
class PublicReferenceBadge extends StatelessWidget {
  const PublicReferenceBadge({
    super.key,
    this.dense = false,
    this.onDark = false,
  });

  final bool dense;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ExperienceView>(
      valueListenable: wiExperienceView,
      builder: (context, view, _) {
        final copy = ExperienceCopy(view);
        final color = onDark ? Colors.white : WiTokens.channelAmber;
        return Tooltip(
          message: copy.badgeTooltip,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 5 : 6,
              vertical: dense ? 1 : 2,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.public, size: dense ? 10 : 11, color: color),
                SizedBox(width: dense ? 3 : 4),
                Text(
                  copy.badgeLabel,
                  style: TextStyle(
                    fontSize: dense ? 9 : 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
