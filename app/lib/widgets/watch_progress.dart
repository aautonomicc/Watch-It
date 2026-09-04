import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';

/// Accent watch-progress bar along a card's bottom edge — how far
/// through a partially watched file the viewer is. Callers place it
/// inside the poster's Stack; [entryWatchBar] returns null when there is
/// nothing to show so the Stack stays untouched.

/// Bar thickness on every card (Continue Watching, wall posters,
/// episode tiles alike).
const double watchBarHeight = 8;

/// The bar itself, for callers that already hold a progress fraction.
Widget watchProgressBar(WiTokens t, double progress) => Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        height: watchBarHeight,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.black45,
          color: t.accent,
        ),
      ),
    );

/// Bar for a movie/episode card from the entry's stored watch state;
/// null when the file is unplayed, finished, or barely started.
Widget? entryWatchBar(WiTokens t, MediaEntry entry) =>
    versionsWatchBar(t, [entry]);

/// Bar for a card folding several uploads of ONE title (quality tiers):
/// the newest watch state across all versions drives it, so progress
/// made on any tier shows on the shared card.
Widget? versionsWatchBar(WiTokens t, List<MediaEntry> versions) {
  final state = WatchStateStore.instance.cachedNewestFor(versions);
  if (state == null || !state.resumable || state.progress <= 0) return null;
  return watchProgressBar(t, state.progress);
}
