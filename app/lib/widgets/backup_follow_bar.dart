import 'package:flutter/material.dart';

import '../services/backup_follow.dart';
import '../theme/tokens.dart';

/// Thin info bar at the bottom of the home screen while a shared-backup
/// fetch runs (the follower-resilience pass, 2026-10-12 round-trip
/// triage item 1): a first-time follow is this device's whole library
/// arriving — "Recovering your library from the backup — 3 of 12" —
/// and it used to run completely invisibly, which is exactly how the
/// live test read it as "not working". Routine catch-ups show too,
/// worded as such. Renders nothing while no fetch is running.
class BackupFollowBar extends StatelessWidget {
  const BackupFollowBar({super.key});

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ValueListenableBuilder<BackupFollowStatus>(
      valueListenable: BackupFollowService.status,
      builder: (context, s, _) {
        if (!s.fetching) return const SizedBox.shrink();
        final what = s.firstTime
            ? 'Recovering your library from the backup'
            : 'Catching up from the backup';
        final detail = s.total > 0 ? ' — ${s.done} of ${s.total}' : '…';
        return Material(
          color: t.ink2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.total > 0)
                LinearProgressIndicator(
                  value: (s.done / s.total).clamp(0.0, 1.0),
                  minHeight: 2,
                  color: t.accent,
                  backgroundColor: t.line,
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: t.accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$what$detail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: t.boneDim),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
