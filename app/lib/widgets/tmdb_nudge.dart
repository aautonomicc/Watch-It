import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../theme/tokens.dart';

/// Whether the keyless-metadata nudge should appear on the home screen:
/// no TMDB credential in effect and the banner not yet dismissed.
Future<bool> shouldShowTmdbNudge() async {
  if (await AppSettings.tmdbNudgeDismissed()) return false;
  return await AppSettings.tmdbKeySource() == TmdbKeySource.none;
}

/// One-time dismissible banner nudging keyless users toward a free TMDB
/// key. Releases ship without one, so posters and descriptions only
/// appear after the user adds theirs (or imports a bundle carrying
/// them). Tapping the banner opens Settings; the close button dismisses
/// it for good.
class TmdbNudgeBanner extends StatelessWidget {
  const TmdbNudgeBanner({
    super.key,
    required this.onOpenSettings,
    required this.onDismiss,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Material(
      color: t.ink2,
      child: InkWell(
        onTap: onOpenSettings,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Row(
            children: [
              Icon(Icons.image_search_outlined, color: t.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Add a free TMDB API key in Settings → Metadata '
                  'for posters & details.',
                  style: TextStyle(fontSize: 12, color: t.boneDim),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, size: 16, color: t.ash),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
