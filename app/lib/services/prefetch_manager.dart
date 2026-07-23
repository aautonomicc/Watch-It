import 'package:flutter/foundation.dart';

import '../models/media_list.dart';
import 'datamap_prefetch.dart';

/// App-wide owner of at most one data-map prefetch run.
///
/// The run lives here rather than in a screen so the progress dialog can
/// be hidden (the prefetch keeps going in the background) and reopened
/// later from Settings → Media Lists, where the same action also resumes
/// a cancelled run: maps already stored resolve from disk in
/// milliseconds, so re-running over a full list only pays for the files
/// that are still missing.
class PrefetchManager extends ChangeNotifier {
  PrefetchManager._();

  static final PrefetchManager instance = PrefetchManager._();

  DataMapPrefetcher? _prefetcher;
  Future<PrefetchResult>? _run;

  /// Progress of the active run: 1-based file number, total, file name.
  int current = 0;
  int total = 0;
  String fileName = '';

  bool get running => _run != null;

  /// The active run's completion, or null when idle. Awaiting this is how
  /// a reopened progress dialog knows when to close.
  Future<PrefetchResult>? get activeRun => _run;

  /// Start prefetching [entries] unless a run is already active, in which
  /// case that run is returned instead (the UI offers to watch it rather
  /// than queueing another).
  Future<PrefetchResult> start(List<MediaEntry> entries, {String? base}) {
    final active = _run;
    if (active != null) return active;
    final prefetcher = DataMapPrefetcher(base: base);
    _prefetcher = prefetcher;
    current = 0;
    total = entries.length;
    fileName = '';
    notifyListeners();
    return _run = prefetcher.run(
      entries,
      onProgress: (c, t, name) {
        current = c;
        total = t;
        fileName = name;
        notifyListeners();
      },
    ).whenComplete(() {
      _run = null;
      _prefetcher = null;
      notifyListeners();
    });
  }

  /// Cancel the active run (no-op when idle).
  void cancel() => _prefetcher?.cancel();
}

/// One-line outcome of a finished run for the summary snackbar.
String prefetchSummary(PrefetchResult result, int total) {
  if (result.cancelled) {
    return 'Prefetch cancelled — ${result.done} of $total data '
        '${total == 1 ? 'map' : 'maps'} saved. Resume any time from '
        'Settings → Media Lists.';
  }
  return 'Prefetched ${result.done} data '
      '${result.done == 1 ? 'map' : 'maps'}'
      '${result.failed > 0 ? ' (${result.failed} failed — those '
          'resolve on first play instead)' : ''}';
}
