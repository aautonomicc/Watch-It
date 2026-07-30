import 'package:flutter/material.dart';

import '../screens/downloads_screen.dart';
import '../services/download_manager.dart';
import '../theme/tokens.dart';

/// Home app-bar meter for the download queue: a circular percent ring
/// with a `x of y` finished count beside it, visible only while
/// something is queued or downloading. Tap opens Settings → Downloads.
class DownloadsIndicator extends StatelessWidget {
  const DownloadsIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final batch = DownloadManager.instance.batchProgress;
        if (batch == null) return const SizedBox.shrink();
        return Tooltip(
          message: 'Downloads: ${batch.done} of ${batch.total} finished',
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      value: batch.progress,
                      strokeWidth: 2.5,
                      color: t.accent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${batch.done} of ${batch.total}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: t.boneDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
