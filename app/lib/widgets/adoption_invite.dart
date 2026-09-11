import 'package:flutter/material.dart';

import '../services/experience_view.dart';
import '../theme/tokens.dart';

/// Invitation card: emotion + a clear verb. Focusable for TV remotes.
class AdoptionInviteCard extends StatelessWidget {
  const AdoptionInviteCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.emphasized = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Material(
      color: emphasized ? t.ink2 : t.ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: emphasized ? t.accent : t.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Icon(icon, color: emphasized ? t.accent : t.boneDim, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: t.bone,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: TextStyle(color: t.ash, fontSize: 12.5, height: 1.35),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: t.ash),
            ],
          ),
        ),
      ),
    );
  }
}

/// Receive / add-from-file pair used on My Media and the home empty wall.
class AdoptionInvitePair extends StatelessWidget {
  const AdoptionInvitePair({
    super.key,
    required this.onReceive,
    required this.onAddFile,
  });

  final VoidCallback onReceive;
  final VoidCallback onAddFile;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ExperienceView>(
      valueListenable: wiExperienceView,
      builder: (context, view, _) {
        final copy = ExperienceCopy.of(context, view);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdoptionInviteCard(
              icon: Icons.card_giftcard_outlined,
              title: copy.receiveDoorTitle,
              body: copy.receiveDoorBody,
              emphasized: true,
              onTap: onReceive,
            ),
            const SizedBox(height: 10),
            AdoptionInviteCard(
              icon: Icons.download_outlined,
              title: copy.fileDoorTitle,
              body: copy.fileDoorBody,
              onTap: onAddFile,
            ),
            if (copy.fileDoorTechnical != null) ...[
              const SizedBox(height: 10),
              Text(
                copy.fileDoorTechnical!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: WiTokens.of(context).ash,
                  height: 1.35,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
