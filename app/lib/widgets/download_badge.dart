import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../theme/tokens.dart';

/// Corner badges telling a card's download state apart at a glance:
/// an accent-blue check = downloaded, a progress ring = download under way
/// (queued/paused/failed included — a partial file lives on disk), and
/// no badge = plain streaming. Show/season cards aggregate: a `3/8`
/// count once ANY episode is downloaded, the full check when all are.
///
/// Callers place the badge inside the poster's Stack; it pins itself to
/// the top-right corner. Helpers return null when there is no badge so
/// the Stack stays untouched for stream-only cards.

/// Badge for a single movie/episode card, from the entry's download
/// task; null when the entry has never been queued.
Widget? entryDownloadBadge(WiTokens t, MediaEntry entry) {
  final task = DownloadManager.instance.taskFor(entry.address);
  if (task == null) return null;
  if (task.status == DownloadStatus.done) return _check(t);
  // Determinate even while the size is unknown (a forever-spinning ring
  // on a wall card is noise, and never settles in widget tests).
  return _ring(t, task.progress ?? 0.0);
}

/// Badge for a show/season card covering [episodes]: `done/total` once
/// any episode is fully downloaded, the plain check when every one is;
/// null while none are.
Widget? groupDownloadBadge(WiTokens t, Iterable<MediaEntry> episodes) {
  var done = 0, total = 0;
  for (final e in episodes) {
    total++;
    if (DownloadManager.instance.taskFor(e.address)?.status ==
        DownloadStatus.done) {
      done++;
    }
  }
  if (done == 0 || total == 0) return null;
  if (done == total) return _check(t);
  return _pin(Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.download_done, size: 11, color: t.accent),
        const SizedBox(width: 3),
        Text(
          '$done/$total',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: t.bone,
          ),
        ),
      ],
    ),
  ));
}

Widget _check(WiTokens t) => _pin(Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: t.accent,
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
      ),
      child: Icon(Icons.check, size: 14, color: t.ink),
    ));

Widget _ring(WiTokens t, double progress) => _pin(Container(
      width: 20,
      height: 20,
      padding: const EdgeInsets.all(3.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        shape: BoxShape.circle,
      ),
      child: CircularProgressIndicator(
        value: progress.clamp(0.0, 1.0),
        strokeWidth: 2,
        color: t.accent,
        backgroundColor: Colors.white24,
      ),
    ));

Widget _pin(Widget child) => Positioned(top: 5, right: 5, child: child);
