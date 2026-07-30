import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/prefetch_manager.dart';
import '../theme/tokens.dart';

/// App-wide messenger so a prefetch hidden in the background can still
/// report its outcome, whatever screen is on top by then. Attached to the
/// MaterialApp in main().
final GlobalKey<ScaffoldMessengerState> wiMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void _showSnack(BuildContext context, String message) {
  final messenger =
      wiMessengerKey.currentState ?? ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}

/// Start prefetching [entries] and watch it in the progress dialog. If a
/// run is already active it is watched instead of starting another. The
/// summary snackbar is attached to the run itself, so it shows exactly
/// once — whether the dialog was watched, hidden, or reopened.
Future<void> startPrefetchWithProgress(
  BuildContext context,
  List<MediaEntry> entries, {
  String? base,
}) {
  final manager = PrefetchManager.instance;
  if (!manager.running) {
    final run = manager.start(entries, base: base);
    unawaited(run.then((result) {
      final summary = prefetchSummary(result, manager.total);
      final global = wiMessengerKey.currentState;
      if (global != null) {
        global.showSnackBar(SnackBar(content: Text(summary)));
      } else if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(summary)));
      }
    }));
  }
  return watchPrefetch(context);
}

/// Show the progress dialog for the active run until it finishes, is
/// cancelled, or the user hides it. Hiding keeps the prefetch going in
/// the background — it can be reopened from Settings → Media Lists.
Future<void> watchPrefetch(BuildContext context) async {
  final manager = PrefetchManager.instance;
  final future = manager.activeRun;
  if (future == null) return;
  var hidden = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PrefetchProgressDialog(
      onCancel: manager.cancel,
      onHide: () {
        hidden = true;
        Navigator.of(dialogContext, rootNavigator: true).pop();
        _showSnack(
            context,
            'Prefetch continues in the background — reopen it from '
            'Settings → Media Lists.');
      },
    ),
  ));
  await future;
  if (!hidden && context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Modal shown while data maps prefetch: spinner with `File X of N` and
/// the name of the file being fetched underneath (live from
/// [PrefetchManager]), plus Hide (keep going in the background) and
/// Cancel (stop after aborting the in-flight file).
class PrefetchProgressDialog extends StatelessWidget {
  const PrefetchProgressDialog({
    super.key,
    required this.onCancel,
    required this.onHide,
  });

  final VoidCallback onCancel;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final manager = PrefetchManager.instance;
    return Dialog(
      backgroundColor: t.ink2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: t.accent),
            const SizedBox(height: 18),
            ListenableBuilder(
              listenable: manager,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'File ${manager.current} of ${manager.total}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.bone,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    manager.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onCancel,
                  child: Text('Cancel', style: TextStyle(color: t.ash)),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onHide,
                  child: Text('Hide', style: TextStyle(color: t.accent)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
